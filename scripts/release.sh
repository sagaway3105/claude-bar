#!/bin/zsh
# ビルド → zip化 → GitHub Release 作成までを一括で行う
# 使い方: ./scripts/release.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?使い方: ./scripts/release.sh <バージョン>  例: ./scripts/release.sh 1.0.0}"

VERSION="$VERSION" ./scripts/make-app.sh

ZIP="build/ClaudeBar-v${VERSION}.zip"
rm -f "$ZIP"
# ditto はシンボリックリンクやメタデータを保った macOS 標準の zip 化手段
ditto -c -k --keepParent build/ClaudeBar.app "$ZIP"

# Developer ID署名済み かつ notary認証情報（claudebar-notary プロファイル）があれば公証する
# ※ grep -q はpipefail下でSIGPIPE(141)になるため変数に受けてから判定する
SIGN_INFO=$(codesign -dvv build/ClaudeBar.app 2>&1 || true)
if [[ "$SIGN_INFO" == *"Developer ID"* ]] &&
   xcrun notarytool history --keychain-profile claudebar-notary >/dev/null 2>&1; then
  echo "📤 Appleへ公証を申請中（数分かかります）..."
  xcrun notarytool submit "$ZIP" --keychain-profile claudebar-notary --wait
  xcrun stapler staple build/ClaudeBar.app
  # ステープル済みアプリでzipを作り直す
  rm -f "$ZIP"
  ditto -c -k --keepParent build/ClaudeBar.app "$ZIP"
  echo "✅ 公証完了（Gatekeeperの警告なしで起動できます）"
else
  echo "ℹ️ 公証はスキップ（Developer ID証明書またはnotary認証情報が未設定）"
fi

gh release create "v${VERSION}" "$ZIP" --title "v${VERSION}" --generate-notes
echo "✅ GitHub Release作成: https://github.com/sagaway3105/claude-bar/releases/tag/v${VERSION}"

# Sparkle: zipをEdDSA署名してappcast.xmlに追記し、pushする（自動アップデート配信）
SPARKLE_TOOLS=".build/artifacts/sparkle/Sparkle/bin"
if [[ -x "$SPARKLE_TOOLS/sign_update" ]]; then
  python3 scripts/appcast_add.py "$VERSION" "$ZIP" "$SPARKLE_TOOLS"
  git add docs/appcast.xml
  git commit -q -m "appcast: v${VERSION} を配信

Claude-Session: https://claude.ai/code/session_01S4fGVycDVJZaRMgQrh1EEp"
  git push -q
  echo "📡 appcast.xml を更新・push（既存ユーザーへ自動アップデート配信）"
else
  echo "⚠️ Sparkleツールが見つからないためappcast更新をスキップ（swift build後に再実行してください）"
fi
