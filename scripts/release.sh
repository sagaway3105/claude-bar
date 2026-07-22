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

# Homebrew tap（sagaway3105/homebrew-tap）のcaskを新バージョンへ更新してpush
TAP_DIR="$(brew --repository sagaway3105/tap 2>/dev/null || true)"
if [[ -n "$TAP_DIR" && -d "$TAP_DIR" ]]; then
  SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
  /usr/bin/python3 - "$VERSION" "$SHA" "$TAP_DIR" <<'PY'
import re, sys
version, sha, tap = sys.argv[1:4]
path = f"{tap}/Casks/claudebar.rb"
s = open(path).read()
s = re.sub(r'version "[^"]+"', f'version "{version}"', s, count=1)
s = re.sub(r'sha256 "[^"]+"', f'sha256 "{sha}"', s, count=1)
open(path, "w").write(s)
PY
  git -C "$TAP_DIR" -c user.name=sagaway3105 -c user.email=253613309+sagaway3105@users.noreply.github.com \
    commit -aqm "claudebar ${VERSION}"
  git -C "$TAP_DIR" push -q
  echo "🍺 Homebrew tap を v${VERSION} に更新"
else
  echo "⚠️ tap未取得のためHomebrew更新をスキップ（brew tap sagaway3105/tap を実行してください）"
fi
