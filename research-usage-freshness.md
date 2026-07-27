# 調査依頼: Claudeプラン使用量を「キーチェーンダイアログなし」で5分未満の鮮度で取得する方法

あなたはWeb調査を行うリサーチャーです。以下の背景と確定事実を前提に、調査課題に答えてください。
**すべての主張に出典URL（公式ドキュメント・GitHubソースコード・issue等）を付けてください。**
憶測と事実を明確に区別し、確定事実と矛盾する情報を見つけた場合はその根拠を示してください。

---

## 背景

- 対象アプリ: **ClaudeBar** — Claudeのプラン使用量（現在のセッション5時間枠 / 週間制限の%）をmacOSメニューバーに常駐表示する個人開発アプリ（Swift製・非公式）
- 表示したいのは **サーバー側の公式な使用率%**（Claude Codeの `/usage` コマンドやClaude.aiの設定画面と同じ数値）。トークン数からの自前推計ではない
- 譲れない制約: **macOSキーチェーンの許可ダイアログを一切表示しない**こと
- 目標: ユーザーが設定した更新間隔（最短1分）どおりに%が更新されること
- 環境: macOS / Claude Code **v2.1.220** / Pro・Maxプラン（サブスクリプション認証）

## 現在の実装と問題

ClaudeBarの現行取得方式:
1. `~/.claude.json` の `cachedUsageUtilization`（Claude Codeが書く使用量キャッシュ。`fetchedAtMs`と`utilization`を含む）を読む
2. キャッシュが更新間隔より古ければ `claude --safe-mode -p "/usage" --no-session-persistence` を起動し、Claude Code自身に更新させる

**問題: Claude Code内部にキャッシュTTL（実測で約5分以上）があり、TTL以内は上記コマンドを実行してもキャッシュが更新されない。** そのため実効的な表示鮮度が5〜8分に制限され、1分間隔の設定が意味を持たない。

## 実測で確定済みの事実（2026-07-27検証・再調査不要）

1. キャッシュ年齢162秒の状態で `claude --safe-mode -p "/usage" --no-session-persistence` を実行 → **exit 0（1.6秒）だが `fetchedAtMs` は更新されない**
2. 同コマンドの**stdout（画面出力）の%値はキャッシュと完全一致**（135秒古いキャッシュと同値）。stdoutをパースしてもTTLは回避できない
3. キャッシュの自然更新間隔は実測7〜17分（アクティブなClaude Codeセッションが動いている状態で 13:19 → 13:27 → 13:34 → 13:51）
4. このMacに `~/.claude/.credentials.json` は**存在しない**（トークンはKeychain「Claude Code-credentials」のみ）
5. OAuthトークンは頻繁にローテーションされる（Keychain項目のmdatが当日中に更新されるのを確認）。他アプリが項目の秘密データを読むと許可ダイアログが出る。「常に許可」もClaude Codeが項目を書き換えるとACLごとリセットされ、ダイアログが再発する
6. `/api/oauth/usage`（非公開API）はBearerトークン+`anthropic-beta: oauth-2025-04-20`+`User-Agent: claude-code/<ver>`で公式%値を返す。API通信自体にダイアログは無関係（問題はトークン入手のみ）
7. Keychain項目の**属性のみの照会**（kSecReturnAttributes）はダイアログなしで可能（mdat取得に使用中）

## 調査課題

### A. Claude Code本体の公式機能で回避できないか（最有望仮説から順に）

1. **statusline**: Claude Codeのカスタムstatusline（settings.jsonの`statusLine`）に渡されるstdin JSONのスキーマを特定してほしい。**プラン使用量（rate limit / session・weekly の使用率%）は含まれるか？どのバージョンから？フィールド名は？**
   - 含まれるなら「ClaudeBarがstatuslineスクリプトを登録→会話のたびに最新%がファイルに書き出される」というダイアログなし・準リアルタイムのルートが成立する
   - 公式ドキュメント（code.claude.com/docs のstatusline項）とchangelogを確認すること
2. **hooks**: hooksイベント（PreToolUse/PostToolUse/Stop等）のstdin JSONに使用量情報は含まれるか？
3. **TTL回避**: `cachedUsageUtilization`のTTLの正確な値・更新条件。TTLを無視して強制再取得させるフラグ・環境変数・サブコマンド（`claude usage`等）は存在するか？
4. **`claude setup-token`**: 発行される長期トークンの保存場所・スコープ。`/api/oauth/usage`に使えるか？使えるなら「ユーザーが一度だけsetup-tokenを実行してClaudeBarに渡す」構成でダイアログなしAPI直叩きが恒久的に成立するか？
5. **OTELテレメトリ**: `CLAUDE_CODE_ENABLE_TELEMETRY`のメトリクスにプラン使用率%は含まれるか？
6. **APIレスポンスヘッダ**: Anthropic APIの`anthropic-ratelimit-unified-*`系ヘッダにプラン使用率が入っているという情報はあるか？Claude Codeがそれをローカルファイルに書き出しているか？

### B. 類似OSSツールはどう解決しているか

以下のツール（+新たに見つけたもの）の**実際のソースコード**を確認し、使用量%の取得経路を特定してほしい:

- steipete/CodexBar（macOSメニューバー・Claude対応）
- ryoppippi/ccusage（CLI）
- Claude-Code-Usage-Monitor / claude-monitor 系
- Raycast の Claude 使用量系拡張
- claude-powerline などstatusline系
- その他「Claude usage menu bar」系ツール

各ツールについて: 取得経路（API直叩き/キャッシュ読み/jsonl自前集計/statusline）、トークンの入手元、キーチェーンダイアログへの対処（README/issueでの言及）、更新頻度、公式%か自前推計か。

### C. その他の可能性

- 自前OAuthフロー（Claude CodeのクライアントIDでPKCEログイン）を実装しているツールはあるか？その場合のAnthropic利用規約上の位置づけは？（2026-02更新のLegal and complianceは第三者アプリによるClaude.aiログイン提供を禁止している認識。これとの整合性）
- `~/.claude.json` の `cachedUsageUtilization.fetchedAtMs` を過去に書き換えてTTLを錯覚させる案について、`~/.claude.json`への外部書き込みの安全性（Claude Codeとの書き込み競合）に関する知見・事例はあるか？

## 出力形式

1. **結論サマリ**: 「キーチェーンダイアログなしで5分未満の鮮度の公式%を得る現実的な方法」の候補を有望順にランク付け（実現可能性・実装コスト・規約リスク・保守リスク付き）
2. 課題A〜Cの各項目: 結論（可能/不可能/不明）+ 具体的仕様（フィールド名・コマンド・バージョン）+ 出典URL
3. 確定事実と矛盾する発見があれば明示

日本語で報告してください。
