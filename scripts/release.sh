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
echo "✅ リリース完了: https://github.com/sagaway3105/claude-bar/releases/tag/v${VERSION}"
