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
APK_NAME="CarSentinelCarUnit-release-unsigned.apk"
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

# ---------- 6. 收集产物 ----------
APK_GLOB="$ANDROID_DIR/app/build/outputs/apk/release/*.apk"
shopt -s nullglob
APKS=($APK_GLOB)
shopt -u nullglob

if [[ ${#APKS[@]} -eq 0 ]]; then
  err "没有找到 release APK: $APK_GLOB"
  exit 1
fi

mkdir -p "$OUT_DIR"
DEST="$OUT_DIR/$APK_NAME"
cp -f "${APKS[0]}" "$DEST"

SIZE_BYTES="$(stat -c '%s' "$DEST" 2>/dev/null || wc -c < "$DEST")"
SHA256="$(sha256sum "$DEST" | awk '{print $1}')"

log "=================================================="
log "APK     : $DEST"
log "Size    : $SIZE_BYTES bytes ($(( SIZE_BYTES / 1024 )) KB)"
log "SHA-256 : $SHA256"
log "=================================================="
