#!/usr/bin/env bash
set -euo pipefail

APP_NAME="NewFinder"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
STAGING_DIR="$BUILD_DIR/dmg-root"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
ICON_PNG="$BUILD_DIR/AppIcon-1024.png"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
mkdir -p "$DIST_DIR"

swift "$ROOT_DIR/Tools/MakeIcon.swift" "$ICON_PNG"
mkdir -p "$ICONSET_DIR"
sips -z 16 16 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ICON_PNG" "$APP_DIR/Contents/Resources/AppIcon.png"

SOURCES=(
  "$ROOT_DIR/Sources/main.swift"
  "$ROOT_DIR/Sources/AppDelegate.swift"
  "$ROOT_DIR/Sources/StatusBarController.swift"
  "$ROOT_DIR/Sources/SystemUsageMonitor.swift"
  "$ROOT_DIR/Sources/ClickableStatusLabel.swift"
  "$ROOT_DIR/Sources/NewItemMenu.swift"
  "$ROOT_DIR/Sources/TrackpadGestureMonitor.swift"
  "$ROOT_DIR/Sources/SwipeDetector.swift"
  "$ROOT_DIR/Sources/TrackpadGesturePreferences.swift"
  "$ROOT_DIR/Sources/DoubleCommandDetector.swift"
  "$ROOT_DIR/Sources/AppSwitcherWindowController.swift"
  "$ROOT_DIR/Sources/FinderActivationIntent.swift"
  "$ROOT_DIR/Sources/ShowDesktopAction.swift"
  "$ROOT_DIR/Sources/WatchAgentMain.swift"
  "$ROOT_DIR/Sources/Models.swift"
  "$ROOT_DIR/Sources/PerfLog.swift"
  "$ROOT_DIR/Sources/FileOperations.swift"
  "$ROOT_DIR/Sources/AppUninstallSupport.swift"
  "$ROOT_DIR/Sources/ArchiveEngine.swift"
  "$ROOT_DIR/Sources/ArchiveSupport.swift"
  "$ROOT_DIR/Sources/ArchiveDialogs.swift"
  "$ROOT_DIR/Sources/ArchiveWindowController.swift"
  "$ROOT_DIR/Sources/OpenWithSupport.swift"
  "$ROOT_DIR/Sources/CompareSession.swift"
  "$ROOT_DIR/Sources/TextDiffEngine.swift"
  "$ROOT_DIR/Sources/CompareViewController.swift"
  "$ROOT_DIR/Sources/SideBySideManager.swift"
  "$ROOT_DIR/Sources/FinderVolumeGuard.swift"
  "$ROOT_DIR/Sources/DMGInstallSupport.swift"
  "$ROOT_DIR/Sources/DMGInstallWindowController.swift"
  "$ROOT_DIR/Sources/OfficeDocumentStubs.swift"
  "$ROOT_DIR/Sources/BrowserWindowController.swift"
  "$ROOT_DIR/Sources/BrowserPaneController.swift"
  "$ROOT_DIR/Sources/ChromeHeaderView.swift"
  "$ROOT_DIR/Sources/ContentViewController.swift"
  "$ROOT_DIR/Sources/ColumnBrowserView.swift"
  "$ROOT_DIR/Sources/SettingsWindowController.swift"
  "$ROOT_DIR/Sources/WeChatDualOpen.swift"
  "$ROOT_DIR/Sources/QuitAppsWindowController.swift"
  "$ROOT_DIR/Sources/ActivityMonitorViewController.swift"
  "$ROOT_DIR/Sources/TemperatureSensorReader.swift"
  "$ROOT_DIR/Sources/TemperatureViewController.swift"
  "$ROOT_DIR/Sources/UpdateChecker.swift"
  "$ROOT_DIR/Sources/BookmarksUI.swift"
  "$ROOT_DIR/Sources/FavoritesSidebarViewController.swift"
)

swiftc \
  -O \
  -whole-module-optimization \
  -target arm64-apple-macos13.0 \
  "${SOURCES[@]}" \
  -import-objc-header "$ROOT_DIR/Sources/NativeHelpers.h" \
  "$ROOT_DIR/Sources/NativeHelpers.m" \
  -framework AppKit \
  -framework QuickLookUI \
  -framework ServiceManagement \
  -framework CoreServices \
  -framework CoreGraphics \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME"

if [[ "$(uname -m)" == "arm64" ]]; then
  TMP_ARM="$BUILD_DIR/$APP_NAME-arm64"
  TMP_X86="$BUILD_DIR/$APP_NAME-x86_64"
  cp "$APP_DIR/Contents/MacOS/$APP_NAME" "$TMP_ARM"
  if swiftc \
    -O \
    -whole-module-optimization \
    -target x86_64-apple-macos13.0 \
    "${SOURCES[@]}" \
    -import-objc-header "$ROOT_DIR/Sources/NativeHelpers.h" \
    "$ROOT_DIR/Sources/NativeHelpers.m" \
    -framework AppKit \
    -framework QuickLookUI \
    -framework ServiceManagement \
    -framework CoreServices \
    -framework CoreGraphics \
    -o "$TMP_X86" 2>/dev/null; then
    lipo -create "$TMP_ARM" "$TMP_X86" -output "$APP_DIR/Contents/MacOS/$APP_NAME"
  fi
fi

cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

# Nested watch helper with a different bundle ID so Launch Services won't treat
# the background agent as "NewFinder already running".
WATCH_APP="$APP_DIR/Contents/Helpers/NewFinderWatch.app"
mkdir -p "$WATCH_APP/Contents/MacOS"
cp "$ROOT_DIR/WatchInfo.plist" "$WATCH_APP/Contents/Info.plist"
cp "$APP_DIR/Contents/MacOS/$APP_NAME" "$WATCH_APP/Contents/MacOS/NewFinderWatch"

# Sign with the stable Developer ID when one is available.
#
# The ad-hoc signature (`-`) changes on every build, which makes macOS treat
# the app as a *different* app and drop the permissions the user granted
# (辅助功能 / 输入监控) — the trackpad gesture would stop working after every
# rebuild. A Developer ID signature is stable, so the grants survive.
#
# The identity is addressed by its SHA hash: several certificates share the
# same common name, and codesign refuses an ambiguous name.
#
# The chosen hash is recorded in `.signing-identity`. If a later build picks a
# *different* certificate, the granted permissions silently stop matching and
# the gesture dies — so the change is reported loudly.
SIGN_IDENTITY="${NF_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "3rd Party Mac Developer Application" \
    | head -1 \
    | grep -oE '[A-F0-9]{40}' \
    | head -1)"
fi

SIGN_IDENTITY_FILE="$ROOT_DIR/.signing-identity"
if [[ -n "$SIGN_IDENTITY" && -f "$SIGN_IDENTITY_FILE" ]]; then
  PREVIOUS_IDENTITY="$(cat "$SIGN_IDENTITY_FILE" 2>/dev/null || true)"
  if [[ -n "$PREVIOUS_IDENTITY" && "$PREVIOUS_IDENTITY" != "$SIGN_IDENTITY" ]]; then
    echo "WARNING: signing certificate changed ($PREVIOUS_IDENTITY -> $SIGN_IDENTITY)."
    echo "         The 辅助功能 / 输入监控 permissions granted for the old build no"
    echo "         longer apply. The user has to re-enable them in"
    echo "         系统设置 → 隐私与安全性, otherwise the trackpad gesture"
    echo "         silently stops working."
  fi
fi
[[ -n "$SIGN_IDENTITY" ]] && echo "$SIGN_IDENTITY" > "$SIGN_IDENTITY_FILE"

if [[ -n "$SIGN_IDENTITY" ]]; then
  if codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" 2>/dev/null; then
    echo "Signed with Developer ID: $SIGN_IDENTITY"
  else
    codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true
    echo "Signed ad-hoc (Developer ID signing failed — permissions may reset on rebuild)"
  fi
else
  codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true
  echo "Signed ad-hoc (no Developer ID found — permissions may reset on rebuild)"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist")"
rm -f "$DMG_PATH" "$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto --norsrc --noextattr "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ln -sf /Applications "$STAGING_DIR/Applications"
xattr -cr "$STAGING_DIR/$APP_NAME.app" 2>/dev/null || true

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"

cp "$DMG_PATH" "$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
xattr -cr "$DMG_PATH" "$DIST_DIR/${APP_NAME}-${VERSION}.dmg" 2>/dev/null || true

echo "Built $APP_DIR"
echo "Built $DMG_PATH"
ls -lh "$APP_DIR/Contents/MacOS/$APP_NAME" "$DMG_PATH"
