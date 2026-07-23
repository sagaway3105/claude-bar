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

# Sparkle.framework を Contents/Frameworks に同梱（自動アップデート用）
SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  # -R でシンボリックリンク(Versions/Current 等)を保ったままコピー
  cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
fi

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
	<string>14.0</string>
	<key>CFBundleAllowMixedLocalizations</key>
	<true/>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>Claude Codeのログインをターミナルで起動するために使用します。</string>
	<key>SUFeedURL</key>
	<string>https://raw.githubusercontent.com/sagaway3105/claude-bar/main/docs/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>V4/WjEP/6rfm8Avez5FhQwTuHebW5LncwugED9dvg6A=</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
</dict>
</plist>
EOF

# Hardened Runtime下でAppleEvents送信（ターミナルでのログイン起動）を許可
cat > "build/entitlements.plist" <<ENTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.automation.apple-events</key>
	<true/>
</dict>
</plist>
ENTEOF

# 署名の優先順: Developer ID（配布用・Hardened Runtime付き）> Apple Development > ad-hoc
# ※ grep不一致でもpipefailで落ちないよう || true を付ける
DEVID=$(security find-identity -p codesigning -v 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)
if [[ -n "${DEVID}" ]]; then
  SIGN_ID="${DEVID}"; RUNTIME=(--options runtime --timestamp)
  echo "🔏 Developer ID署名: ${DEVID}"
elif [[ -n "${IDENTITY}" ]]; then
  SIGN_ID="${IDENTITY}"; RUNTIME=()
else
  SIGN_ID="-"; RUNTIME=()
fi

# Sparkle同梱時は内側(XPC/ヘルパーapp)→フレームワーク→本体の順で署名する
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$FW" ]]; then
  for inner in \
    "$FW/Versions/B/XPCServices/Downloader.xpc" \
    "$FW/Versions/B/XPCServices/Installer.xpc" \
    "$FW/Versions/B/Updater.app" \
    "$FW/Versions/B/Autoupdate"; do
    [[ -e "$inner" ]] && codesign --force "${RUNTIME[@]}" --sign "${SIGN_ID}" "$inner"
  done
  codesign --force "${RUNTIME[@]}" --sign "${SIGN_ID}" "$FW"
fi

# 本体（entitlementsはDeveloper ID時のみ・ad-hoc/開発署名でも動く）
codesign --force "${RUNTIME[@]}" --entitlements build/entitlements.plist --sign "${SIGN_ID}" "$APP"

echo "✅ ${APP} を生成しました"
echo "   open '${APP}' で起動できます"
