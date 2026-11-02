# ClaudeBar

- 作業が終わったら `/release-prep`（`.claude/skills/release-prep/SKILL.md`）で、コードレビュー、リリースノートの下書き、README の最新化まで進めて止まる。
- 公開は必ず本人の最終承認を待つ。`scripts/release.sh`、タグの作成、`main` への push やマージを、指示なしに行わない。確認入力を代行しない。
- 変更時は旧OS互換を確かめる（`CLAUDEBAR_FORCE_LEGACY=1 swift test --build-system native`）。
- 不具合を直したら、再発防止をテストか `docs/RELEASE_CHECKLIST.md` に追加する。
