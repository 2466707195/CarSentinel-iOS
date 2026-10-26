#!/bin/bash
# =============================================================================
# iOS 云端构建 —— 编译出【未签名 .ipa】
#
# 在任意 macOS 环境（本地 / GitHub Actions / Codemagic）编译出设备包。
# 产出的 ipa 不带签名，供「全能签 / 爱思助手 / ESign」等工具重签后安装。
#
# app 名从 project.yml 的 `name:` 自动读取，不用改脚本。
#
# 用法：bash scripts/build-unsigned-ipa.sh
# =============================================================================
set -euo pipefail

# ---- 定位工程根目录（兼容「仓库根 = 工程目录」和「仓库根 = 上级目录」两种放法）----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if   [ -f "$SCRIPT_DIR/../project.yml" ];                 then ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
elif [ -f "$SCRIPT_DIR/../../*/project.yml" ];             then ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  echo "!! 找不到 project.yml，请确认本脚本位于工程目录的 scripts/ 下" >&2
  exit 1
fi
cd "$ROOT"
echo "==> 工程目录: $ROOT"

# ---- 读 app 名 ----
APP_NAME="$(grep -E '^[[:space:]]*name:' project.yml | head -1 | sed -E 's/^[[:space:]]*name:[[:space:]]*//' | tr -d "\"'" | xargs)"
if [ -z "$APP_NAME" ]; then
  echo "!! 无法从 project.yml 读到 name:" >&2
  exit 1
fi
echo "==> App 名: $APP_NAME"

# ---- 检查工具链 ----
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "!! 找不到 xcodegen。执行： bash scripts/install-xcodegen.sh" >&2
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "!! 找不到 xcodebuild（Xcode 未安装或未选择）" >&2
  exit 1
fi

XCODE_VER="$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')"
XCODE_MAJOR="${XCODE_VER%%.*}"
echo "    xcode: ${XCODE_VER:-unknown}"

# ---- iOS SDK 版本检查 ----
# 本工程用了 iOS 18（Tab）和 iOS 26（glassEffect / GlassEffectContainer /
# ToolbarSpacer / UITabAccessory）的 API。SDK 里没有这些符号的话，
# @available 守卫救不了 —— 编译器直接报 cannot find type 'Glass' in scope。
SDK_VER="$(xcodebuild -showsdks 2>/dev/null | grep -oE 'iphoneos[0-9.]+' | head -1 | grep -oE '[0-9.]+$')"
SDK_MAJOR="${SDK_VER%%.*}"
echo "    iphoneos sdk: ${SDK_VER:-unknown}"
if [ -n "$SDK_MAJOR" ] && [ "$SDK_MAJOR" -lt 26 ]; then
  echo "!! SDK 太旧：当前是 iOS ${SDK_VER} SDK（Xcode ${XCODE_VER}）。" >&2
  echo "   本工程需要 iOS 26 SDK，因为用了 glassEffect / GlassEffectContainer /" >&2
  echo "   ToolbarSpacer / UITabAccessory，以及 iOS 18 的 Tab。" >&2
  echo "   解决办法：换 Xcode 26+ 编译。CI 里用 macos-15 runner 并挑最新的 Xcode。" >&2
  exit 1
fi

# ---- 1. 生成 Xcode 工程 ----
echo ""
echo "==> [1/4] xcodegen generate"
xcodegen generate

# 生成后立刻验证工程可读：能在真正编译前抓到「工程格式过新」这类问题
echo ""
echo "==> [1b/4] 校验工程可读性"
if ! xcodebuild -list -project "${APP_NAME}.xcodeproj" >/dev/null 2>&1; then
  echo "!! Xcode 打不开刚生成的工程。" >&2
  if [ -n "$XCODE_MAJOR" ] && [ "$XCODE_MAJOR" -lt 16 ]; then
    echo "   最可能的原因：XcodeGen 版本太新（>= 2.42 会写 objectVersion 77，只有 Xcode 16+ 能开）。" >&2
    echo "   当前 Xcode 是 ${XCODE_VER}。" >&2
    echo "   解决办法： bash scripts/install-xcodegen.sh    （装固定的 2.38.0）" >&2
  else
    echo "   请手动执行 xcodebuild -list -project ${APP_NAME}.xcodeproj 查看详细错误。" >&2
  fi
  exit 1
fi
echo "    ok"

# ---- 2. 编译（Release / 真机 arm64 / 关闭签名）----
echo ""
echo "==> [2/4] xcodebuild（Release · generic/platform=iOS · 不签名）"
rm -rf build
mkdir -p build
# 日志同时落盘：本机浏览器常常连不上 GitHub，构建失败时只能靠 artifact 把日志带回来
set +e
xcodebuild \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee build/xcodebuild.log
XCODE_RC=${PIPESTATUS[0]}
set -e
if [ "$XCODE_RC" -ne 0 ]; then
  echo ""
  echo "!! xcodebuild 失败 (exit $XCODE_RC)。日志末尾 100 行：" >&2
  tail -100 build/xcodebuild.log >&2
  echo "" >&2
  echo "   完整日志已存到 build/xcodebuild.log，会随 artifact 一起上传。" >&2
  exit "$XCODE_RC"
fi

# ---- 3. 打包成未签名 ipa ----
echo ""
echo "==> [3/4] 打包 Payload/${APP_NAME}.app"
APP="build/DerivedData/Build/Products/Release-iphoneos/${APP_NAME}.app"
if [ ! -d "$APP" ]; then
  echo "!! 没有找到编译产物：$APP" >&2
  echo "   请检查上面 xcodebuild 的报错。" >&2
  exit 1
fi

rm -rf build/Payload
mkdir -p build/Payload
cp -R "$APP" build/Payload/
# 确保没有任何签名残留，交给重签工具处理
rm -rf "build/Payload/${APP_NAME}.app/_CodeSignature" 2>/dev/null || true
rm -f  "build/Payload/${APP_NAME}.app/embedded.mobileprovision" 2>/dev/null || true

# 顺带把 Info.plist 转成 JSON 一份（Xcode 产物的 Info.plist 是二进制 plist，
# Windows 上不好读；转成 JSON 后随 artifact 一起带走，方便在电脑上验收）
if command -v plutil >/dev/null 2>&1; then
  plutil -convert json -o build/Info.json "build/Payload/${APP_NAME}.app/Info.plist" 2>/dev/null || \
  plutil -convert xml1 -o build/Info.plist.xml "build/Payload/${APP_NAME}.app/Info.plist" 2>/dev/null || true
  echo "    Info.json: $([ -f build/Info.json ] && echo ok || echo skipped)"
fi

# ---- 4. zip 成 ipa ----
echo ""
echo "==> [4/4] 生成 ${APP_NAME}-unsigned.ipa"
rm -f "build/${APP_NAME}-unsigned.ipa"
( cd build && zip -qry "${APP_NAME}-unsigned.ipa" Payload )
rm -rf build/Payload

echo ""
echo "============================================================"
echo " 完成：$(pwd)/build/${APP_NAME}-unsigned.ipa"
echo " 大小：$(du -h "build/${APP_NAME}-unsigned.ipa" | cut -f1)"
echo " 下一步：把该 ipa 传到「全能签」→ 选证书重签 → 下载签名包 → 装到手机"
echo "============================================================"
