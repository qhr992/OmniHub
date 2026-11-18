#!/bin/bash
# Builds OmniHub and wraps it in one DMG to hand to someone else:
#   dist/OmniHub-<version>.dmg  =  OmniHub.app + an Applications shortcut + 安装说明.txt
# The recipient needs nothing else (no project, no Xcode tools).
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh >/dev/null
APP=build/OmniHub.app
VERSION=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)
NAME="OmniHub-$VERSION"
mkdir -p dist
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/OmniHub.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/安装说明.txt" <<TXT
OmniHub ${VERSION}（macOS 14 及以上，Intel / Apple Silicon 通用）

1. 把 OmniHub 拖到右边的 Applications（应用程序）文件夹。
2. 第一次打开：在「应用程序」里双击 OmniHub。系统提示无法验证开发者时点「完成」，
   然后打开 系统设置 → 隐私与安全性，在下方找到 OmniHub，点「仍要打开」，再输入密码确认。
   （或者在终端执行一次：xattr -dr com.apple.quarantine /Applications/OmniHub.app）
3. 按提示授权：屏幕录制（截图必需）；辅助功能、日历按需。授权后重启一次 OmniHub。

以后收到新版本，同样拖进去覆盖即可，已经给过的授权不用再给。
TXT

rm -f "dist/$NAME.dmg"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO "dist/$NAME.dmg"
shasum -a 256 "dist/$NAME.dmg" | tee "dist/$NAME.dmg.sha256"
codesign -dvv "$APP" 2>&1 | grep -E "^Authority" || true
ls -lh "dist/$NAME.dmg"
