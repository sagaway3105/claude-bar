#!/bin/bash
# Issue #1 の外向き対応を一括実行するスクリプト。
#
#   実行方法:  bash docs/issue-drafts/issue-1-publish.sh
#
# やること（すべて冪等・追記済みならスキップ）:
#   1. v1.3.0〜v1.5.2 のリリースページ先頭に警告を追記（Finder/unzip展開で署名破壊）
#   2. v1.0.0〜v1.2.0 のリリースページ先頭に警告を追記（unzip展開のみ）
#   3. v1.5.3 のリリースページ末尾に「Finderも影響」の訂正を追記
#   4. Issue #1 に issue-1-reply.md の内容で返信
#
# ※ 返信内の✅（README・CI・アプリ側修正）は main への push 後に事実になります。
#    先に今回の変更をコミット & push してから実行するのがおすすめです。
# ※ 編集前の各リリース本文のバックアップ:
#    ~/.claude/jobs/759575c6/tmp/release-bodies/*.md（ジョブ削除で消えます）
set -euo pipefail
REPO=sagaway3105/claude-bar

STRONG='> [!WARNING]
> **この配布 zip には AppleDouble（`._*`）ファイルが混入しており、Finder（ダブルクリック）や `unzip` で展開するとコード署名が壊れます。**「"ClaudeBar" は開発元を検証できないため開けません」と表示されたり、自動アップデートが完了しない原因になります。
> **[最新版](https://github.com/sagaway3105/claude-bar/releases/latest) をご利用ください。** すでにこのバージョンを展開・起動してしまった場合の復旧手順は [Issue #1](https://github.com/sagaway3105/claude-bar/issues/1) をご覧ください。
'

MILD='> [!WARNING]
> **この配布 zip には AppleDouble（`._*`）ファイルが混入しており、`unzip` コマンドで展開するとコード署名が壊れます**（Finder でのダブルクリック展開は影響ありません）。
> **[最新版](https://github.com/sagaway3105/claude-bar/releases/latest) をご利用ください。** 復旧手順は [Issue #1](https://github.com/sagaway3105/claude-bar/issues/1) をご覧ください。
'

CORRECTION='**【2026-08-27 訂正】** 上記で「Finderでのダブルクリック展開・Homebrew・アプリ内の自動アップデートは影響を受けていません」と記載しましたが、**Finder（アーカイブユーティリティ）での展開も v1.3.0〜v1.5.2 では署名が壊れる**ことを確認しました。訂正してお詫びします。原因は `Sparkle.framework` 内のシンボリックリンクに対する `._*` が実ファイルとして残るためです。詳細と復旧手順は [Issue #1](https://github.com/sagaway3105/claude-bar/issues/1) をご覧ください。'

annotate() {
  local tag=$1 note=$2 body
  body=$(gh release view "$tag" --repo "$REPO" --json body --jq .body)
  if [[ "$body" == *AppleDouble* ]]; then
    echo "スキップ: $tag（追記済み）"
    return
  fi
  printf '%s\n%s' "$note" "$body" | gh release edit "$tag" --repo "$REPO" --notes-file -
  echo "✏️  $tag に警告を追記しました"
}

for v in v1.3.0 v1.4.0 v1.4.1 v1.4.2 v1.5.0 v1.5.1 v1.5.2; do annotate "$v" "$STRONG"; done
for v in v1.0.0 v1.1.0 v1.2.0; do annotate "$v" "$MILD"; done

body=$(gh release view v1.5.3 --repo "$REPO" --json body --jq .body)
if [[ "$body" == *訂正* ]]; then
  echo "スキップ: v1.5.3（訂正済み）"
else
  printf '%s\n\n---\n\n%s' "$body" "$CORRECTION" | gh release edit v1.5.3 --repo "$REPO" --notes-file -
  echo "✏️  v1.5.3 に訂正を追記しました"
fi

gh issue comment 1 --repo "$REPO" --body-file "$(dirname "$0")/issue-1-reply.md"
echo "💬 Issue #1 に返信を投稿しました"
