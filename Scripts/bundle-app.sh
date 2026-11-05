#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="NotchSpace"
BUNDLE_ID="dev.4hhuang.NotchSpace"
BUILD_APP_DIR="$ROOT_DIR/build/${APP_NAME}.app"
INSTALL_APP_DIR="$HOME/Applications/${APP_NAME}.app"

echo "==> Building ${APP_NAME} (Release)..."
cd "$ROOT_DIR"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"

echo "==> Packaging ${BUILD_APP_DIR}..."
rm -rf "$BUILD_APP_DIR"
mkdir -p "$BUILD_APP_DIR/Contents/MacOS"
mkdir -p "$BUILD_APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$BUILD_APP_DIR/Contents/MacOS/${APP_NAME}"
chmod +x "$BUILD_APP_DIR/Contents/MacOS/${APP_NAME}"

cat > "$BUILD_APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$BUILD_APP_DIR"

mkdir -p "$HOME/Applications"
rm -rf "$INSTALL_APP_DIR"
cp -R "$BUILD_APP_DIR" "$INSTALL_APP_DIR"

echo "==> Successfully packaged:"
echo "    Build:     $BUILD_APP_DIR"
echo "    Installed: $INSTALL_APP_DIR"
