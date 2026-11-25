#!/bin/bash
# Build OmniHub.app — universal binary, no third-party dependencies.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/OmniHub.app"
BUNDLE_ID="com.local.omnihub"
MIN_MACOS="14.0"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=(
  Sources/main.swift
  Sources/Localization.swift
  Sources/L10nSelfTest.swift
  Sources/UpdateChecker.swift
  Sources/UpdateSelfTest.swift
  Sources/Support.swift
  Sources/HotKey.swift
  Sources/HotKeyCenter.swift
  Sources/SettingsPane.swift
  Sources/SidebarList.swift
  Sources/MainWindow.swift
  Sources/MenuBarPanel.swift
  Sources/MainWindowMotion.swift
  Sources/MainHome.swift
  Sources/MainHomeTiles.swift
  Sources/MainSelfTest.swift
  Sources/ScreenCapture.swift
  Sources/WindowPicker.swift
  Sources/Annotate.swift
  Sources/Overlay.swift
  Sources/SelectionEdit.swift
  Sources/SnipTools.swift
  Sources/SnipToolbar.swift
  Sources/SnipSelfTest.swift
  Sources/PinnedImageWindow.swift
  Sources/ScrollStitcher.swift
  Sources/ScrollCapture.swift
  Sources/ScrollKeys.swift
  Sources/ScrollSelfTest.swift
  Sources/Store.swift
  Sources/TaskStore.swift
  Sources/ClipboardStore.swift
  Sources/MediaObserver.swift
  Sources/PlayerActivity.swift
  Sources/PlayerMenu.swift
  Sources/LyricsProvider.swift
  Sources/ClipboardPane.swift
  Sources/ShelfStore.swift
  Sources/ShelfPane.swift
  Sources/AgendaPane.swift
  Sources/Holidays.swift
  Sources/StatusRunner.swift
  Sources/TerminalBuffer.swift
  Sources/TerminalKeymap.swift
  Sources/TerminalSession.swift
  Sources/TerminalCursor.swift
  Sources/TerminalPane.swift
  Sources/TerminalSettingsView.swift
  Sources/ConnectionStore.swift
  Sources/VaultSelfTest.swift
  Sources/NetHelpers.swift
  Sources/RemoteFiles.swift
  Sources/RemoteViews.swift
  Sources/ServerTunnels.swift
  Sources/RemoteSelfTest.swift
  Sources/SystemStats.swift
  Sources/ActivityView.swift
  Sources/ActivityExtras.swift
  Sources/KeepAwake.swift
  Sources/Battery.swift
  Sources/TopApps.swift
  Sources/StatusIcon.swift
  Sources/StatusIconColors.swift
  Sources/SettingsSection.swift
  Sources/SettingsAppearance.swift
  Sources/StatusSelfTest.swift
  Sources/BootAnimation.swift
  Sources/MarqueeLabel.swift
  Sources/FloatingDockPanel.swift
  Sources/DockSelfTest.swift
  Sources/KeyboardFocus.swift
  Sources/TabSelfTest.swift
)

echo "==> compiling (arm64)"
swiftc -O -wmo -swift-version 5 \
  -target "arm64-apple-macos${MIN_MACOS}" \
  -o build/OmniHub-arm64 "${SOURCES[@]}"

echo "==> compiling (x86_64)"
swiftc -O -wmo -swift-version 5 \
  -target "x86_64-apple-macos${MIN_MACOS}" \
  -o build/OmniHub-x86_64 "${SOURCES[@]}"

echo "==> lipo"
lipo -create -output "$APP/Contents/MacOS/OmniHub" \
  build/OmniHub-arm64 build/OmniHub-x86_64

cp Resources/Info.plist "$APP/Contents/Info.plist"
# Interface translations (English is the development language, in the code).
cp -R Resources/zh-Hans.lproj "$APP/Contents/Resources/"

# Character media (Lan: boot film, avatar, backdrop, icon) is original art
# made in Tools/boot-film (make-assets.sh) and committed in Resources/character.
ICON_SOURCE="Resources/AppIcon.png"
if [ -d Resources/character ]; then
  echo "==> character media"
  for f in BootAnimation.mp4 Avatar.png Background.jpg; do
    [ -f "Resources/character/$f" ] && cp "Resources/character/$f" "$APP/Contents/Resources/$f"
  done
  [ -f Resources/character/AppIcon.png ] && ICON_SOURCE="Resources/character/AppIcon.png"
else
  echo "==> character media missing (Tools/boot-film/make-assets.sh rebuilds it)"
fi

echo "==> icon"
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON_SOURCE" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$ICON_SOURCE" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Now-playing bridge: a dylib that /usr/bin/perl loads (see MediaBridge.m).
echo "==> media bridge"
clang -dynamiclib -fobjc-arc -O2 \
  -arch arm64 -arch x86_64 "-mmacosx-version-min=${MIN_MACOS}" \
  -framework Foundation \
  -o "$APP/Contents/Resources/MediaBridge.dylib" Sources/MediaBridge/MediaBridge.m
cp Sources/MediaBridge/bridge.pl "$APP/Contents/Resources/bridge.pl"

# Prefer the fixed local identity (permissions survive rebuilds); fall back
# to ad-hoc if it cannot be set up.
# OMNIHUB_ADHOC=1 skips the identity entirely (compile checks on a machine
# where the app is not going to be installed).
if [ "${OMNIHUB_ADHOC:-}" = "1" ]; then
  IDENTITY=""
else
  IDENTITY="$(Tools/setup-signing.sh || true)"
fi
if [ -n "$IDENTITY" ]; then
  echo "==> signing (local identity $IDENTITY)"
else
  IDENTITY="-"
  echo "==> signing (ad-hoc: permissions must be re-granted after every build)"
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Contents/Resources/MediaBridge.dylib" 2>/dev/null
# Hardened Runtime: no injected libraries (DYLD_INSERT_LIBRARIES) or
# unsigned code in the app's process. MediaBridge.dylib is loaded by
# /usr/bin/perl, not by the app, so it is not affected.
codesign --force --sign "$IDENTITY" --timestamp=none --options runtime \
  --entitlements Resources/OmniHub.entitlements "$APP" 2>/dev/null
codesign --verify --deep --strict "$APP"

echo "==> done"
file "$APP/Contents/MacOS/OmniHub"
lipo -archs "$APP/Contents/MacOS/OmniHub"
du -sh "$APP"
echo
echo "Run:      open \"$APP\""
echo "Install:  ./build.sh --install"

if [[ "${1:-}" == "--install" ]]; then
  echo "==> installing to /Applications"
  osascript -e 'tell application id "com.local.omnihub" to quit' >/dev/null 2>&1 || true
  pkill -x OmniHub >/dev/null 2>&1 || true
  sleep 1
  # The app used to be called SnaCut; never leave both running.
  pkill -x SnaCut >/dev/null 2>&1 || true
  rm -rf /Applications/OmniHub.app
  cp -R "$APP" /Applications/OmniHub.app
  open /Applications/OmniHub.app
  echo "installed and launched: /Applications/OmniHub.app"
fi
