#!/bin/bash
# Assembles QuotaBar.app from a release build.
#
# SwiftPM cannot emit an app bundle, so the layout is built by hand: a release binary, an
# Info.plist marking the app as an agent (no Dock icon), and an ad-hoc signature. Ad-hoc is
# enough here because the only keychain read goes through /usr/bin/security, whose access grant
# belongs to that binary rather than to this one.
set -euo pipefail

PRODUCT_NAME="QuotaBar"
APP_NAME="${APP_NAME:-$PRODUCT_NAME}"
BUNDLE_ID="${BUNDLE_ID:-com.quotabar.app}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Release builds pass VERSION from the pushed tag. Local builds use the latest release tag, so a
# release needs no version bump commit.
if [[ -z "${VERSION:-}" ]]; then
    latest_tag="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)"
    VERSION="${latest_tag:-v0.0.0}"
    VERSION="${VERSION#v}"
fi
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

cd "$ROOT"

echo "==> Building release binary"
"$ROOT/Scripts/swift.sh" build -c release --product "$PRODUCT_NAME"
BINARY_DIR="$("$ROOT/Scripts/swift.sh" build -c release --product "$PRODUCT_NAME" --show-bin-path)"
BINARY="$BINARY_DIR/$PRODUCT_NAME"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
cp -R "$BINARY_DIR/QuotaBar_QuotaBarCore.bundle" "$APP/Contents/Resources/"

# macOS 26 and later read the icon from Assets.car; earlier systems read the AppIcon.icns that
# actool writes beside it.
echo "==> Compiling Resources/AppIcon.icon"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun actool \
    "$ROOT/Resources/AppIcon.icon" \
    --compile "$APP/Contents/Resources" \
    --app-icon AppIcon \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$BUILD_DIR/AppIcon.partial.plist" >/dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Built $APP"
du -sh "$APP" | awk '{print "    size: " $1}'
echo "    Run it with: open \"$APP\""
echo "    Install it with: cp -R \"$APP\" /Applications/"
