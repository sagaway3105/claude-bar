# ClaudeBar

- 作業が終わったら `/release-prep`（`.claude/skills/release-prep/SKILL.md`）で、コードレビュー、リリースノートの下書き、README の最新化、チェックまで進めて止まる。
- 公開は必ず本人の最終承認を待つ。公開の内容を報告したあと、本人がチャットで公開を明示するまで `--approved` を付けて `scripts/release.sh` を実行しない。タグの作成や `main` への push やマージを、指示なしに行わない。
- 変更時は旧OS互換を確かめる（`CLAUDEBAR_FORCE_LEGACY=1 swift test --build-system native`）。
- 不具合を直したら、再発防止をテストか `docs/RELEASE_CHECKLIST.md` に追加する。
