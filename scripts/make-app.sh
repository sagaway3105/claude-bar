#!/bin/zsh
# ClaudeBar.app をビルドして build/ に生成する
# VERSION=1.2.3 ./scripts/make-app.sh でバージョン指定（省略時 1.0.0）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"

swift build -c release

# アプリアイコン（無ければ生成）
if [[ ! -f assets/AppIcon.icns ]]; then
  swift scripts/make-icon.swift assets
  iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
fi

APP="build/ClaudeBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/ClaudeBar "$APP/Contents/MacOS/ClaudeBar"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>ClaudeBar</string>
	<key>CFBundleIdentifier</key>
	<string>com.atsushisagae.ClaudeBar</string>
	<key>CFBundleName</key>
	<string>ClaudeBar</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
EOF

# 署名の優先順: Developer ID（配布用・Hardened Runtime付き）> Apple Development > ad-hoc
DEVID=$(security find-identity -p codesigning -v 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
if [[ -n "${DEVID}" ]]; then
  codesign --force --options runtime --timestamp --sign "${DEVID}" "$APP"
  echo "🔏 Developer ID署名: ${DEVID}"
elif [[ -n "${IDENTITY}" ]]; then
  codesign --force --sign "${IDENTITY}" "$APP"
else
  codesign --force --sign - "$APP"
fi

echo "✅ ${APP} を生成しました"
echo "   open '${APP}' で起動できます"
