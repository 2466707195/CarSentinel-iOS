#!/bin/bash
# =============================================================================
# 安装【固定版本】的 XcodeGen
#
# 为什么要锁版本：
#   XcodeGen 2.42+ 会生成 Xcode 16 的工程文件格式（objectVersion = 77），
#   而 Xcode 15.x 只认到 76，于是报：
#       "The project cannot be opened because it is in a future Xcode project
#        file format (77)"
#   XcodeGen 2.38.0 写的是 objectVersion = 54，Xcode 13 ~ 最新版全都能打开。
#   → 锁 2.38.0，兼容性最好。
#
# 覆盖：XCODEGEN_VERSION=2.41.0 bash scripts/install-xcodegen.sh
# =============================================================================
set -euo pipefail

XCODEGEN_VERSION="${XCODEGEN_VERSION:-2.38.0}"
PREFIX="${PREFIX:-/usr/local}"

echo "==> Installing XcodeGen ${XCODEGEN_VERSION} into ${PREFIX}"

# 如果之前用 brew 装过，先卸掉，避免 PATH 里抢占
if command -v brew >/dev/null 2>&1; then
  brew uninstall -f xcodegen >/dev/null 2>&1 || true
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
echo "    $URL"
curl -fsSL -o "$TMP/xcodegen.zip" "$URL"
unzip -q -o "$TMP/xcodegen.zip" -d "$TMP/dl"

sudo mkdir -p "$PREFIX/bin" "$PREFIX/share"
sudo cp -R "$TMP/dl/xcodegen/bin/."  "$PREFIX/bin/"
sudo cp -R "$TMP/dl/xcodegen/share/." "$PREFIX/share/"
sudo chmod +x "$PREFIX/bin/xcodegen"

export PATH="$PREFIX/bin:$PATH"
hash -r 2>/dev/null || true

echo "    installed: $(command -v xcodegen)"
"$PREFIX/bin/xcodegen" --version 2>/dev/null || echo "    (version flag unavailable)"
