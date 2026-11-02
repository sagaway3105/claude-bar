#!/bin/zsh
# リリース前チェック。自動の検査のあと、docs/RELEASE_CHECKLIST.md の手動項目の確認を求める。
# 通過するとコミットごとの記録を残し、release.sh はその記録が無いと配布しない。
# 使い方: ./scripts/preflight.sh 1.7.0   （ターミナルで本人が確認して入力する）
# --confirmed を付けると手動項目の入力を省く（Claude Code が確認を代行し、結果を報告する時に使う）
# --auto-only を付けると自動の検査だけ行い、記録は残さない（開発中の確認用）
set -euo pipefail
cd "$(dirname "$0")/.."
autoload -Uz is-at-least

VERSION="${1:?使い方: ./scripts/preflight.sh <バージョン> [--confirmed|--auto-only]}"
AUTO_ONLY="${2:-}"
NOTES_FILE="docs/release-notes/v${VERSION}.md"
CHECKLIST="docs/RELEASE_CHECKLIST.md"
SHA="$(git rev-parse HEAD)"
RECORD_DIR="build/preflight"

fail() { echo "❌ $*" >&2; exit 1; }

# テストを実行し、件数を確かめる（0件のまま成功扱いになる事故を防ぐ）
run_tests() {
  local label="$1" log
  log="$(mktemp)"
  if ! "${@:2}" >"$log" 2>&1; then
    grep -E 'error:|failed' "$log" | head -20 >&2 || true
    rm -f "$log"
    fail "テストが失敗しました（${label}）"
  fi
  local count
  count=$(grep -oE 'Executed [0-9]+ tests?' "$log" | awk '{print $2}' | sort -n | tail -1 || true)
  rm -f "$log"
  [[ "${count:-0}" -gt 0 ]] || fail "テストが1件も実行されていません（${label}）"
  echo "✅ テスト ${count} 件（${label}）"
}

echo "== 状態とバージョン"
[[ -z "$(git status --porcelain)" ]] || fail "未コミットの変更があります"
LATEST_TAG="$(git tag --sort=-v:refname | head -1)"
if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
  fail "v${VERSION} のタグは既にあります"
fi
is-at-least "${LATEST_TAG#v}" "$VERSION" || fail "v${VERSION} は最新のタグ ${LATEST_TAG} より古いです"
echo "✅ コミット済み、${LATEST_TAG} → v${VERSION}"

echo "== 秘密情報"
./scripts/check-secrets.sh

echo "== リリースノート"
[[ -s "$NOTES_FILE" ]] || fail "$NOTES_FILE がありません"
if grep -nE 'TODO|TBD|下書き' "$NOTES_FILE"; then
  fail "$NOTES_FILE に下書きの印が残っています"
fi
echo "✅ $NOTES_FILE"

echo "== README"
README_JA_CHANGED=0; README_EN_CHANGED=0
git diff --quiet "$LATEST_TAG" HEAD -- README.md || README_JA_CHANGED=1
git diff --quiet "$LATEST_TAG" HEAD -- README.en.md || README_EN_CHANGED=1
if [[ "$README_JA_CHANGED" != "$README_EN_CHANGED" ]]; then
  fail "README.md と README.en.md の片方だけが ${LATEST_TAG} から更新されています"
fi
if [[ "$README_JA_CHANGED" == 1 ]]; then
  echo "✅ 日英とも ${LATEST_TAG} から更新あり"
else
  echo "⚠️ README は ${LATEST_TAG} から更新なし。更新が不要か手動の確認で判断してください"
fi

echo "== テスト"
run_tests "通常" swift test --build-system native
run_tests "旧OS分岐" env CLAUDEBAR_FORCE_LEGACY=1 swift test --build-system native

echo "== .app の組み立てと署名"
VERSION="$VERSION" ./scripts/make-app.sh
codesign --verify --deep --strict build/ClaudeBar.app
echo "✅ 署名の検証"

echo "== 配布 zip"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto -c -k --keepParent --norsrc --noextattr build/ClaudeBar.app "$WORK/check.zip"
if zipinfo -1 "$WORK/check.zip" | grep -E '(^|/)\._' | head -5 | grep .; then
  fail "zip に AppleDouble（._*）が混入しています"
fi
for TOOL in ditto unzip; do
  mkdir "$WORK/$TOOL"
  case "$TOOL" in
    ditto) ditto -x -k "$WORK/check.zip" "$WORK/$TOOL" ;;
    unzip) unzip -qq "$WORK/check.zip" -d "$WORK/$TOOL" ;;
  esac
  codesign --verify --deep --strict "$WORK/$TOOL/ClaudeBar.app"
done
echo "✅ zip の混入なし、展開後の署名も有効"

echo "== CI"
CI_RESULT="$(gh run list --commit "$SHA" --workflow CI --limit 1 --json status,conclusion \
  -q '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null || true)"
if [[ "$CI_RESULT" == "completed success" ]]; then
  echo "✅ CI 成功（${SHA:0:7}）"
elif [[ "$AUTO_ONLY" == "--auto-only" ]]; then
  echo "⚠️ CI が成功していません（${SHA:0:7}: ${CI_RESULT:-未実行}）。リリース時は中断します"
else
  fail "このコミットの CI が成功していません（${SHA:0:7}: ${CI_RESULT:-未実行}）。push して完了を待ってください"
fi

if [[ "$AUTO_ONLY" == "--auto-only" ]]; then
  echo "✅ 自動の検査を通過しました（--auto-only なので記録は残しません）"
  exit 0
fi

echo
echo "== 手動の確認（$CHECKLIST）"
grep -E '^(### |- \[ \] )' "$CHECKLIST"
echo
if [[ "$AUTO_ONLY" == "--confirmed" ]]; then
  echo "✅ 手動項目は確認済みとして進めます（--confirmed）"
else
  [[ -r /dev/tty ]] || fail "確認の入力ができません。ターミナルから実行するか --confirmed を付けてください"
  print -n "すべて確認しましたか？ v${VERSION} と入力すると記録します: " >/dev/tty
  read -r ANSWER </dev/tty
  [[ "$ANSWER" == "v${VERSION}" ]] || fail "確認が取れなかったので記録しません"
fi

mkdir -p "$RECORD_DIR"
date '+%Y-%m-%d %H:%M:%S' > "$RECORD_DIR/v${VERSION}-${SHA}"
echo "✅ リリース前チェックを通過しました（v${VERSION} / ${SHA:0:7}）。release.sh を実行できます"
