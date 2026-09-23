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
VERSION="${VERSION:-1.0.7}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# Optional app icon. Drop a 1024x1024 PNG at Resources/AppIcon.png (or a ready-made
# Resources/AppIcon.icns) and it gets compiled into the bundle; without one the app keeps the
# generic executable icon and everything else still builds.
ICON_PLIST_ENTRY=""
ICON_PNG="$ROOT/Resources/AppIcon.png"
ICON_ICNS="$ROOT/Resources/AppIcon.icns"
if [[ -f "$ICON_ICNS" ]]; then
    echo "==> Using $ICON_ICNS"
    cp "$ICON_ICNS" "$APP/Contents/Resources/AppIcon.icns"
    ICON_PLIST_ENTRY="    <key>CFBundleIconFile</key><string>AppIcon</string>"
elif [[ -f "$ICON_PNG" ]]; then
    echo "==> Compiling $ICON_PNG into AppIcon.icns"
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    # The sizes iconutil expects; each @2x is the next size up rendered at double density.
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z "$((size * 2))" "$((size * 2))" "$ICON_PNG" \
            --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
    ICON_PLIST_ENTRY="    <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

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
$ICON_PLIST_ENTRY
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
