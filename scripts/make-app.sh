#!/bin/zsh
# ClaudeBar.app をビルドして build/ に生成する
# VERSION=1.2.3 ./scripts/make-app.sh でバージョン指定（省略時 1.0.0）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"

# --build-system native は必須: Xcode 27 の既定（swiftbuild）だと実行ファイルの SDK が
# 最低対応OSと同じ 14.0 と記録され、システムの窓やボタンが旧デザインに戻る
swift build -c release --build-system native

# アプリアイコン（無ければ生成）
if [[ ! -f assets/AppIcon.icns ]]; then
  swift scripts/make-icon.swift assets
  iconutil -c icns assets/AppIcon.iconset -o assets/AppIcon.icns
fi

APP="build/ClaudeBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/ClaudeBar "$APP/Contents/MacOS/ClaudeBar"

# 記録された SDK が古いとシステムUIが互換モードになる。ビルド方式の変更で黙って退行しないよう検証する
SDK_VERSION=$(vtool -show-build "$APP/Contents/MacOS/ClaudeBar" | awk '$1 == "sdk" { print $2; exit }')
if (( ${SDK_VERSION%%.*} < 26 )); then
  echo "❌ 実行ファイルの SDK が古すぎます: ${SDK_VERSION}（26 以上が必要）" >&2
  exit 1
fi
echo "✅ 実行ファイルの SDK: ${SDK_VERSION}"

cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# ローカライズ: メインバンドルが「対応している言語」を宣言する必要がある。
# 実際の文字列は SwiftPM のリソースバンドル(ClaudeBar_ClaudeBar.bundle)側にあるが、
# CFBundle の言語解決はメインバンドルの .lproj / CFBundleLocalizations に
# 制限されるため、ここに空の .lproj を置かないと ja が選ばれず英語に固定される
for LANG_DIR in en ja; do
  mkdir -p "$APP/Contents/Resources/$LANG_DIR.lproj"
  : > "$APP/Contents/Resources/$LANG_DIR.lproj/InfoPlist.strings"
done
# 権限の説明文の英語版（Info.plist の本文は日本語）
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS_EOF'
"NSScreenCaptureUsageDescription" = "Measures the brightness behind the bubble so it can adapt to the background. Images are never saved or sent.";
"NSAppleEventsUsageDescription" = "Used to start the Claude Code login in Terminal.";
STRINGS_EOF

# `Bundle.module` の直接使用を禁止する（ResourceBundle.swift の AppResources 経由のみ許可）。
# SwiftPM のアクセサは Contents/Resources を探さないため、配布 .app で必ず落ちる（Issue #2）
if grep -rn "Bundle\.module" Sources/ --include='*.swift' | grep -v "ResourceBundle.swift" | grep -v "^\S*:\s*//" ; then
  echo "❌ Bundle.module を直接使っている箇所があります。AppResources.bundle を使ってください" >&2
  exit 1
fi

# SwiftPMのリソースバンドルを同梱（Localizable.strings・効果音）。
# 無ければ即中断する（黙ってスキップすると、配布先で Bundle 解決に失敗してクラッシュする＝Issue #2）
RES_BUNDLE=".build/release/ClaudeBar_ClaudeBar.bundle"
if [[ ! -d "$RES_BUNDLE" ]]; then
  echo "❌ リソースバンドルが見つかりません: $RES_BUNDLE（swift build -c release を先に）" >&2
  exit 1
fi
cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"

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
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>ja</string>
	</array>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSScreenCaptureUsageDescription</key>
	<string>バブルの裏の明るさを測り、背景に合わせて見た目を切り替えるために使用します。画像は保存も送信もしません。</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>Claude Codeのログインをターミナルで起動するために使用します。</string>
	<!-- フィードは GitHub Pages 経由（docs/appcast.xml を配信）。
	     raw.githubusercontent.com はIP単位のレート制限(429)があり、NAT配下の環境で
	     更新チェックが失敗し得るため。実体は同じ main/docs/appcast.xml なので、
	     旧バージョン(v1.5.2以前)が見ているraw URLもそのまま生き続ける -->
	<key>SUFeedURL</key>
	<string>https://sagaway3105.github.io/claude-bar/appcast.xml</string>
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

# 組み立て検証: 開発機の .build へのフォールバックに頼らず、Contents/Resources から
# 文字列と音が実際に引けるかをアプリ自身に確かめさせる（Issue #2 の再発防止。
# 開発機では常に成功してしまう種類の欠落なので、アプリ側のセルフテストで判定する）
if ! CLAUDEBAR_SELFTEST=resources "$APP/Contents/MacOS/ClaudeBar"; then
  echo "❌ 配布 .app のリソース検証に失敗しました（上の ❌ を参照）" >&2
  exit 1
fi
echo "✅ 配布 .app のリソース検証OK（Contents/Resources から解決）"

echo "✅ ${APP} を生成しました"
echo "   open '${APP}' で起動できます"
