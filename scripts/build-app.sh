#!/bin/zsh
# Build ResSwitch.app, ad-hoc sign it, and produce a zip in dist/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="ResSwitch"
VERSION="1.0.7"
APP="$ROOT/dist/$APP_NAME.app"
ZIP="$ROOT/dist/$APP_NAME-$VERSION.zip"

echo "== Building release executable"
swift build -c release --product "$APP_NAME"

if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
    echo "== Generating icon"
    rm -rf "$ROOT/Resources/AppIcon.iconset"
    swift "$ROOT/scripts/make-icon.swift" "$ROOT/Resources/AppIcon.iconset"
    iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
fi

echo "== Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

echo "== Ad-hoc signing"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "== Creating zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"

echo ""
echo "✅ $APP"
echo "✅ $ZIP"
echo ""
echo "Run: open \"$APP\""
echo "Self-test: \"$APP/Contents/MacOS/$APP_NAME\" --selftest ipad"
