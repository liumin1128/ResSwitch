#!/bin/zsh
# Build ResSwitch.app, ad-hoc sign it, and produce a zip in dist/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="ResSwitch"
VERSION="1.0.4"
APP="$ROOT/dist/$APP_NAME.app"
ZIP="$ROOT/dist/$APP_NAME-$VERSION.zip"

echo "== 构建 release 可执行文件"
swift build -c release --product "$APP_NAME"

if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
    echo "== 生成图标"
    rm -rf "$ROOT/Resources/AppIcon.iconset"
    swift "$ROOT/scripts/make-icon.swift" "$ROOT/Resources/AppIcon.iconset"
    iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
fi

echo "== 组装 App Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

echo "== ad-hoc 签名"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "== 打包 zip"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"

echo ""
echo "✅ $APP"
echo "✅ $ZIP"
echo ""
echo "运行：open \"$APP\""
echo "自检：\"$APP/Contents/MacOS/$APP_NAME\" --selftest ipad"
