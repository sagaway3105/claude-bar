#!/bin/zsh
# 追跡中のファイルに秘密情報らしき値がないか確かめる（CI と preflight.sh から呼ぶ）。
# 過去に Apple のアプリ用パスワードを公開履歴へ入れた事故の再発防止。値は表示しない
set -uo pipefail
cd "$(dirname "$0")/.."
# \b は macOS の git grep -E で効かないので、前後の文字を明示する
PATTERN='(^|[^a-z-])[a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}($|[^a-z-])|sk-ant-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|BEGIN [A-Z ]*PRIVATE KEY'
HITS=$(git grep -nIE "$PATTERN" -- ':!scripts/check-secrets.sh' | cut -d: -f1,2)
FILES=$(git ls-files | grep -iE '(password|\.p8$|\.p12$|\.pem$|\.mobileprovision$)')
if [[ -n "$HITS$FILES" ]]; then
  echo "❌ 秘密情報らしきものが見つかりました（場所のみ表示）:" >&2
  [[ -n "$HITS" ]] && echo "$HITS" >&2
  [[ -n "$FILES" ]] && echo "$FILES" >&2
  exit 1
fi
echo "✅ 秘密情報らしきものなし"
