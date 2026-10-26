#!/usr/bin/env bash
# CarSentinel 360 · Android 车机端一键构建（Linux CI）
#
# 设计目标：在没有 Gradle Wrapper JAR 的 checkout 里也能跑。
# GitHub 的 ubuntu-latest runner 自带 Gradle 与完整 Android SDK，
# 所以优先用系统 gradle；本地若生成了 wrapper 则用 ./gradlew。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ANDROID_DIR="$ROOT_DIR/android"
OUT_DIR="$ROOT_DIR/build"

log() { echo -e "\033[1;36m[build-android]\033[0m $*"; }
err() { echo -e "\033[1;31m[build-android]\033[0m $*" >&2; }

# ---------- 1. SDK ----------
if [[ -z "${ANDROID_HOME:-}" && -z "${ANDROID_SDK_ROOT:-}" ]]; then
  err "ANDROID_HOME / ANDROID_SDK_ROOT 均未设置。请先安装 Android SDK。"
  exit 1
fi
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT}}"
log "Android SDK: $SDK"

# ---------- 2. licenses（防御性） ----------
if [[ -d "$SDK/licenses" ]]; then
  log "licenses 已接受"
else
  log "接受 licenses…"
  yes | sdkmanager --licenses >/dev/null 2>&1 || \
    err "sdkmanager --licenses 失败（runner 通常已预接受，可忽略）"
fi

# ---------- 3. local.properties ----------
if [[ ! -f "$ANDROID_DIR/local.properties" ]]; then
  log "写入 local.properties"
  printf 'sdk.dir=%s\n' "$SDK" > "$ANDROID_DIR/local.properties"
fi

# ---------- 4. 选择 Gradle ----------
GRADLE_CMD=()
if [[ -f "$ANDROID_DIR/gradlew" ]]; then
  log "使用 wrapper: ./gradlew"
  GRADLE_CMD=("$ANDROID_DIR/gradlew")
else
  if ! command -v gradle >/dev/null 2>&1; then
    err "既没有 gradlew，PATH 里也没有 gradle。"
    err "本仓库刻意不提交 wrapper JAR（无法生成二进制），请在 runner 上安装 Gradle："
    err "  sudo apt-get update && sudo apt-get install -y gradle"
    err "或执行 'gradle wrapper' 生成 wrapper 后重试。"
    exit 1
  fi
  log "使用系统 gradle: $(gradle --version | grep -E '^Gradle' | head -1)"
  GRADLE_CMD=(gradle)
fi

# ---------- 5. assembleRelease ----------
cd "$ANDROID_DIR"
log "gradle assembleRelease …"
mkdir -p "$OUT_DIR"
set +e
"${GRADLE_CMD[@]}" assembleRelease --no-daemon --stacktrace 2>&1 | tee "$OUT_DIR/gradle.log"
RC=${PIPESTATUS[0]}
set -e
if [[ $RC -ne 0 ]]; then
  err "assembleRelease 失败 (exit $RC)"
  echo "-------- gradle.log 末尾 120 行 --------" >&2
  tail -120 "$OUT_DIR/gradle.log" >&2
  echo "---------------------------------------" >&2
  err "完整日志在 $OUT_DIR/gradle.log，会随 artifact 一起上传"
  exit $RC
fi

# ---------- 6. 签名 ----------
# 未签名的 APK 装不上（adb install 报 INSTALL_PARSE_FAILED_NO_CERTIFICATES，
# 文件管理器也会拒）。所以这里必须签。
#
# keystore 来源，按优先级：
#   1. 环境变量 ANDROID_KEYSTORE_BASE64（配成 GitHub Secret，实现稳定升级）
#   2. 本地已有的 $OUT_DIR/carsentinel.jks
#   3. 都没有 → 用固定参数现生成一个（首次构建会这样）
#
# ⚠️ 情况 3 意味着每次干净 CI 都会换一把 key。要能覆盖升级，必须把这次的 keystore
#    存成 GitHub Secret（ANDROID_KEYSTORE_BASE64），详见 README「Android 签名」。
KS="$OUT_DIR/carsentinel.jks"
KS_ALIAS="carsentinel"
KS_PASS="carsentinel"

if [[ -n "${ANDROID_KEYSTORE_BASE64:-}" ]]; then
  log "使用 Secret 里的 keystore"
  echo "$ANDROID_KEYSTORE_BASE64" | base64 -d > "$KS"
elif [[ -f "$KS" ]]; then
  log "复用本地 keystore: $KS"
else
  log "生成新 keystore（固定参数，便于之后固化成 Secret）"
  keytool -genkeypair -v \
    -keystore "$KS" \
    -alias "$KS_ALIAS" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$KS_PASS" -keypass "$KS_PASS" \
    -dname "CN=CarSentinel 360, OU=Car, O=CarSentinel, L=NA, C=NA" \
    2>&1 | tail -3
fi

# 找 apksigner：SDK 的 build-tools 下，取最新版
APKSIGNER=""
for d in "$SDK"/build-tools/*/; do
  if [[ -x "${d}apksigner" ]]; then APKSIGNER="${d}apksigner"; fi
done
if [[ -z "$APKSIGNER" ]]; then
  err "找不到 apksigner（$SDK/build-tools/*/apksigner）"
  exit 1
fi
log "apksigner: $APKSIGNER"

# ---------- 7. 收集产物 + 签名 ----------
APK_GLOB="$ANDROID_DIR/app/build/outputs/apk/release/*.apk"
shopt -s nullglob
APKS=($APK_GLOB)
shopt -u nullglob

if [[ ${#APKS[@]} -eq 0 ]]; then
  err "没有找到 release APK: $APK_GLOB"
  exit 1
fi

mkdir -p "$OUT_DIR"
UNSIGNED="${APKS[0]}"
SIGNED="$OUT_DIR/CarSentinelCarUnit-release.apk"

log "签名 $UNSIGNED -> $SIGNED"
"$APKSIGNER" sign \
  --ks "$KS" --ks-pass "pass:$KS_PASS" \
  --key-pass "pass:$KS_PASS" \
  --out "$SIGNED" "$UNSIGNED"
"$APKSIGNER" verify --print-certs "$SIGNED" | head -5

# keystore 也打成 base64 随 artifact 输出，供用户备份 / 配成 Secret
base64 -w0 "$KS" > "$OUT_DIR/carsentinel.jks.base64"
log "keystore 备份: $OUT_DIR/carsentinel.jks.base64（请保存，丢失后无法覆盖升级）"

DEST="$SIGNED"
SIZE_BYTES="$(stat -c '%s' "$DEST" 2>/dev/null || wc -c < "$DEST")"
SHA256="$(sha256sum "$DEST" | awk '{print $1}')"

log "=================================================="
log "APK     : $DEST  (已签名)"
log "Size    : $SIZE_BYTES bytes ($(( SIZE_BYTES / 1024 )) KB)"
log "SHA-256 : $SHA256"
log "=================================================="
