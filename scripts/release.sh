#!/bin/zsh
# ビルド → zip化 → GitHub Release 作成までを一括で行う
# 使い方: ./scripts/release.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?使い方: ./scripts/release.sh <バージョン>  例: ./scripts/release.sh 1.0.0}"

# 配布はmainブランチからのみ（SparkleのフィードURLは main/docs/appcast.xml 固定＝
# GitHub Pages と raw の両方がこれを配信している。別ブランチでappcastをpushしても
# 既存ユーザーに配信されず、成功したように見えてしまう）
CURRENT_BRANCH="$(git branch --show-current)"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "❌ mainブランチで実行してください（現在: ${CURRENT_BRANCH}）" >&2
  exit 1
fi
# ステージ済みの変更があると後段のappcastコミットに混入する
if ! git diff --cached --quiet; then
  echo "❌ ステージ済みの変更があります。コミットまたはunstageしてから実行してください" >&2
  exit 1
fi

VERSION="$VERSION" ./scripts/make-app.sh

# 署名の完全性チェック（壊れた署名のまま配布しない）
codesign --verify --deep --strict build/ClaudeBar.app
echo "✅ codesign検証OK"

ZIP="build/ClaudeBar-v${VERSION}.zip"
rm -f "$ZIP"

# zip内に AppleDouble（._*）が1件でもあれば即中断する。
# ._* は展開時に署名シールを壊す直接原因（Issue #1 / v1.3.0〜v1.5.2 で実際に発生）。
# --norsrc --noextattr の付け忘れ・ditto以外でのzip化・将来の変更をここで検知する
assert_no_appledouble() {
  local entries
  entries=$(zipinfo -1 "$ZIP" | grep -E '(^|/)\._' || true)
  if [[ -n "$entries" ]]; then
    echo "❌ 配布zipに AppleDouble（._*）が混入しています（署名破壊の原因）:" >&2
    echo "$entries" | head >&2
    exit 1
  fi
  echo "✅ zip内 AppleDouble（._*）0件"
}
# ditto はシンボリックリンク（Sparkle.frameworkのVersions等）を保った macOS 標準の zip 化手段。
# --norsrc --noextattr は必須: 付けないと拡張属性が AppleDouble（._*）として同梱され、
# unzip で展開した人だけ「a sealed resource is missing or invalid」で署名が壊れる。
# （Dropbox配下でビルドしていると com.dropbox.attrs が全ファイルに付くため必ず踏む）
ditto -c -k --keepParent --norsrc --noextattr build/ClaudeBar.app "$ZIP"
assert_no_appledouble

# Developer ID署名済み かつ notary認証情報（claudebar-notary プロファイル）があれば公証する
# ※ grep -q はpipefail下でSIGPIPE(141)になるため変数に受けてから判定する
SIGN_INFO=$(codesign -dvv build/ClaudeBar.app 2>&1 || true)
if [[ "$SIGN_INFO" == *"Developer ID"* ]] &&
   xcrun notarytool history --keychain-profile claudebar-notary >/dev/null 2>&1; then
  echo "📤 Appleへ公証を申請中（数分かかります）..."
  xcrun notarytool submit "$ZIP" --keychain-profile claudebar-notary --wait
  xcrun stapler staple build/ClaudeBar.app
  # Gatekeeper実機相当の受け入れ確認（notarized判定にならなければここで止める）
  spctl --assess --type exec -vv build/ClaudeBar.app
  # ステープル済みアプリでzipを作り直す
  rm -f "$ZIP"
  ditto -c -k --keepParent --norsrc --noextattr build/ClaudeBar.app "$ZIP"
assert_no_appledouble
  # build/ のappだけ検証していると「zip化の過程で壊れる」事故を見逃すため、
  # 実際に配る zip を展開し直して確認する。ユーザーの展開方法はFinder(=ditto)と
  # unzip の両方があり得るので両方試す（片方だけ壊れるパターンが実在する）
  for TOOL in ditto unzip; do
    WORK="$(mktemp -d)"
    case "$TOOL" in
      ditto) ditto -x -k "$ZIP" "$WORK" ;;
      unzip) unzip -qq "$ZIP" -d "$WORK" ;;
    esac
    codesign --verify --deep --strict "$WORK/ClaudeBar.app"
    spctl --assess --type exec "$WORK/ClaudeBar.app"
    xcrun stapler validate "$WORK/ClaudeBar.app" >/dev/null
    rm -rf "$WORK"
    echo "✅ 配布zipの検証OK（${TOOL}で展開）"
  done
  echo "✅ 公証完了（Gatekeeperの警告なしで起動できます）"
else
  # make-app.sh は証明書が無いと ad-hoc 署名へ黙ってフォールバックする。
  # 未公証・ad-hoc のまま配布するとGatekeeperにブロックされるため、ここで必ず止める
  echo "❌ 公証できません（Developer ID証明書またはnotary認証情報 claudebar-notary が未設定）" >&2
  echo "   未公証ビルドの配布は事故のもとなので中断します" >&2
  exit 1
fi

# docs/release-notes/v<バージョン>.md があればそれをノートに使う（無ければ自動生成）
NOTES_FILE="docs/release-notes/v${VERSION}.md"
if [[ -f "$NOTES_FILE" ]]; then
  gh release create "v${VERSION}" "$ZIP" --title "v${VERSION}" --notes-file "$NOTES_FILE"
else
  gh release create "v${VERSION}" "$ZIP" --title "v${VERSION}" --generate-notes
fi
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
