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

gh release create "v${VERSION}" "$ZIP" --title "v${VERSION}" --generate-notes
echo "✅ リリース完了: https://github.com/sagaway3105/claude-bar/releases/tag/v${VERSION}"
