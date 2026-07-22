# ClaudeBar 🫧

Claudeのプラン使用量をmacOSメニューバーに常駐表示するネイティブアプリ。

メニューバー: `42% ✳` — 現在のセッション使用量% + Claudeロゴ。
Claude Codeがトークン消費中はロゴが回転しながら脈打ち、80%で橙・95%で赤に変わります。

## 機能

- **メニューバー表示**: 現在のセッション（5時間ウィンドウ）の使用量%とロゴ。数字はぬるっと変化（numericText）
- **パネル**（クリックで展開・Liquid Glass）
  - 現在のセッション / 週間制限（すべてのモデル・Fable）を残り時間つきゲージで表示
  - Fableのラベルは APIの `limits[]` から動的取得（Opusプランなら"Opus"）
  - **ペース予測**: 直近6時間の消費ペースから「このペースだと◯曜◯時に週間上限」を表示
  - 追加利用（extra usage）が有効な場合は消費額も表示
- **Tear-off**: グリップをドラッグして引き剥がすと「ぷるんっ」（ジェリー変形+ハプティクス）と共に**フローティングパネル**になる（外側クリックで閉じなくなる）
- **浮遊モード🫧**: 丸いガラスのバブルが**画面全体をゆっくり漂いながら**常時最前面で使用量リングを表示
  - 軌道は数秒先まで物理シミュレーションし`CAKeyframeAnimation`でレンダーサーバに委譲 — アプリが忙しくても**ディスプレイのリフレッシュレート（ProMotionなら120Hz）で滑らか**
  - クリックでポヨン、**3連打で破裂💥** / ドラッグで移動 / 右クリックでメニュー
  - パネルを見たい時はメニューバーのアイコンをクリック（バブルは通常パネルに戻る）
  - 表示する使用量は設定で選択可（セッション / 週間 / Fable）
  - **メニューバーへドラッグすると吸い込まれて戻る**
- **割れる💥**: バブル中に使用量100%到達で、Popサウンド+衝撃波+飛沫と共にシャボン玉のように割れる
  - **復活**: セッションのリセット時刻を過ぎると「ぽわんっ」と自動復活（設定でオフ可）
- **通知**: 80% / 95% 到達時に通知センターへ（設定でオフ可）
- **自動アップデート**: 新しいバージョンが出ると Sparkle が知らせてワンクリックで更新（EdDSA署名で検証・設定でオフ可）
- **設定**: ログイン時に自動起動（SMAppService）/ 更新間隔（1・2・5分）/ 通知 / バブルの表示メトリクスと復活 / 自動アップデート
- **ログイン導線**: 認証情報が無い/期限切れの場合はパネルに「Claude Codeにログイン」ボタンが出て、ターミナルで `claude /login` を起動
- **右クリックメニュー**（メニューバーアイコン）: 今すぐ更新 / バブルで表示 / アップデートを確認 / 設定 / 終了

## 動作環境

- macOS 26 (Tahoe) 以降 — Liquid Glass (`NSGlassEffectView`) を使用
- Apple Silicon (arm64)
- Claude Code がログイン済みであること（Pro / Max プラン）

## インストール

### Homebrew（おすすめ）

```sh
brew install --cask sagaway3105/tap/claudebar
```

### 手動ダウンロード

1. [Releases](https://github.com/sagaway3105/claude-bar/releases/latest) から `ClaudeBar-vX.X.X.zip` をダウンロードして解凍
2. `ClaudeBar.app` を **アプリケーション** フォルダに移動してダブルクリック
   - v1.2.0以降は**Apple公証済み**（Developer ID署名）なので、そのまま起動できます

どちらの方法でも、メニューバーに「–% ✳」が出たら成功。あとは下の「初めて使う人のセットアップ」へ。以降の更新はアプリ内の自動アップデート（Sparkle）が知らせてくれます。

## 💰 追加課金は不要です

このアプリは **Claude Codeのサブスクリプション認証（OAuthトークン）を読み取り専用で流用**します。
APIキー（従量課金）は使いません。使用量の取得はClaude Code本体の `/usage` と同じ照会用エンドポイントで、
トークン消費にもカウントされません。

## 初めて使う人のセットアップ（アカウント連携の流れ）

ClaudeBar自体にアカウント情報を入力する画面は**ありません**（規約上、第三者アプリがClaudeログインを提供できないため）。連携は公式のClaude Codeログインをそのまま使います:

1. **Claude Codeをインストール**（未導入の場合）: `npm install -g @anthropic-ai/claude-code`
   - 普段Claude Codeを使わない人（Claude.aiのWeb/アプリ派）も、**ログインのためだけに一度インストールすればOK**です。以降CLIを使う必要はなく、ClaudeBarはアカウント全体の使用量（Web/アプリ分も含むサーバ側の数値）を表示します
   - ※APIキー（従量課金）のみの利用者は、プランの5時間/週間上限自体が存在しないため対象外です
2. **ClaudeBarを起動** → メニューバーに「–% ✳」が出る。パネルを開くと「認証情報が見つかりません」の案内と **「Claude Codeにログイン」ボタン** が表示される
3. ボタンを押すとターミナルで `claude /login` が起動 → ブラウザで**Claude公式のログイン画面**が開くので、自分のClaudeアカウント（Pro/Max）でログイン
4. ログイン完了でトークンがKeychainに保存される。ClaudeBarが次の更新（最大2分、またはパネルの↻）で自動的に拾い、使用量が表示される
5. 初回のKeychainアクセス時にmacOSの許可ダイアログが出るので **「常に許可」** を選ぶ

つまり「どのアカウントの使用量が表示されるか」=「そのMacのClaude Codeにログインしているアカウント」です。パスワード等がClaudeBarを経由することは一切ありません。

## ビルドと起動

```sh
# .appバンドルの生成（アイコン生成込み）
./scripts/make-app.sh
open build/ClaudeBar.app

# 開発中の実行
swift run

# テスト
swift test
```

初回起動時、Keychainの「Claude Code-credentials」への読み取り許可ダイアログが表示されます。
**「常に許可」** を選択してください（Apple Development証明書で署名しているため再ビルド後も許可は維持されます）。

## 仕組み

| 何を | どうやって |
|---|---|
| 使用量% | Claude CodeのOAuthトークン（Keychain）を読み取り専用で流用し、`GET https://api.anthropic.com/api/oauth/usage` をポーリング（`claude-code/<version>` UA必須・429時は5分クールダウン） |
| 消費中の検知 | `~/.claude/projects/**/*.jsonl`（セッショントランスクリプト）への書き込みをFSEventsで監視 |
| トークン更新 | 自前ではrefreshしない。期限切れ時はClaude Code本体を使うと自動更新される |
| ペース予測 | 週間使用量のサンプルをUserDefaultsに蓄積し、直近6時間を最小二乗法で外挿 |

## UI検証用デバッグモード

```sh
CLAUDEBAR_DEBUG=1 CLAUDEBAR_FAKE=1 CLAUDEBAR_CMDFILE=/tmp/cbcmd ./.build/debug/ClaudeBar
echo "usage:83,41,12" >> /tmp/cbcmd   # フェイクデータ注入
echo "bubble" >> /tmp/cbcmd           # バブル表示
echo "usage:100,41,12" >> /tmp/cbcmd  # → 割れる
```
コマンド: `click` `bubble` `expand` `pop` `hide` `settings` `quit` `state` `usage:s,w,f` `active:0/1` `err:msg`

## 制約・注意

- API課金（`ANTHROPIC_API_KEY`）のみの利用では使えません（サブスクリプション専用エンドポイントのため）
- `/api/oauth/usage` は非公開APIのため、仕様変更で動かなくなる可能性があります
- トークンに `user:profile` スコープが必要です（通常の `claude /login` なら付与されます）

## 認証と規約について（配布に関する重要事項）

本アプリはAnthropic非公式のツールです。設計上、次の方針を採っています:

- **自前のログイン画面は持ちません。** Anthropicの公式ポリシー（2026-02更新の Legal and compliance）は、第三者アプリが「Claude.aiログインを提供する」こと、およびFree/Pro/Maxプランの認証情報を経由してリクエストを代行することを禁止しています。ClaudeBarはユーザー自身がClaude Codeでログインした認証情報を**読み取り専用**で参照するだけです
- **トークンのrefresh（更新）は行いません。** refresh tokenのローテーションはClaude Code本体に任せます（二重refreshによる認証破壊と、規約上のリスクの両方を避けるため）
- **推論APIは一切呼びません。** トークン消費を伴わない使用量照会のみです
- それでも `/api/oauth/usage` は非公開エンドポイントであり、Anthropicは予告なくアクセス制御を変更できます。その場合このアプリの使用量表示は動作しなくなります（同種のOSSツール — CodexBar、Raycast拡張など — と同じ立ち位置です）
- v1.2.0以降は **Developer ID署名 + Apple公証済み** で配布しています（Gatekeeperの警告なしで起動できます）
