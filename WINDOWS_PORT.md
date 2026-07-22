# Windows対応 方針メモ

macOS版 ClaudeBar（Swift + AppKit）を Windows に対応させるための方針。
**Windows実機で実装作業する前提の作業メモ。**

---

## 0. 決定事項：方針A（別ネイティブ実装）

- macOS版は **Swift のまま**維持（完成済み・公証パイプラインを活かす）。
- Windows版は **別コードベースで新規実装**する（共通化はしない）。
- 共有するのは「思想」と「APIの叩き方」だけ。コードは共有しない。

理由: Mac App Store のサンドボックス問題とは別に、AppKit は macOS 専用でそのまま動かないため。
共通化（Tauri等）は「完成済みSwift版を捨てる」判断になるので今回は見送り。

---

## 1. 技術スタック（推奨）

| 項目 | 推奨 | 備考 |
|---|---|---|
| 言語/ランタイム | **C# / .NET 8 以降** | Windows常駐アプリの王道。トレイ・資格情報API・署名まで揃う |
| UIフレームワーク | **WinForms**（`NotifyIcon`）+ ボーダーレスForm | トレイ常駐は WinForms が最短。ポップアップパネルは自前Formで描画 |
| HTTP | `HttpClient` | |
| JSON | `System.Text.Json` | |
| 配布 | 単一exe（`dotnet publish -p:PublishSingleFile=true`）| |

> WPF でも可（`Hardcodet.NotifyIcon.Wpf` 等が必要）。UIにこだわるならWPF、最短ならWinForms。

---

## 2. 【最重要・先にやること】認証情報の在り処を確定する

macOS版は Keychain のジェネリックパスワード `Claude Code-credentials` から読み、
失敗したら `~/.claude/.credentials.json`（平文JSON）にフォールバックしている
（`Sources/ClaudeBar/Services/CredentialsStore.swift` 参照）。

**Windowsで Claude Code がトークンをどこに保存しているかを、実機で最初に確認する。**
候補は2つ：

### 候補① Windows資格情報マネージャー（Credential Manager）
- 「資格情報マネージャー」→「Windows資格情報」→ 汎用資格情報
- ターゲット名はおそらく `Claude Code-credentials`
- C#からは `CredRead` (P/Invoke) か NuGet `Meziantou.Framework.Win32.CredentialManager` で読む
- 中身は下記と同じJSON文字列のはず

### 候補② 平文ファイル
- `%USERPROFILE%\.claude\.credentials.json`
- C#: `Path.Combine(Environment.GetFolderPath(SpecialFolder.UserProfile), ".claude", ".credentials.json")`
- **macOS版のフォールバックと同じ形式なので、ここが存在すれば実装は一気に楽になる**

### 確認コマンド（Windows実機で）
```powershell
# ファイルの有無と中身
type "$env:USERPROFILE\.claude\.credentials.json"

# 資格情報マネージャー（GUI）
control /name Microsoft.CredentialManager
# または
cmdkey /list | findstr /i claude
```

> どちらが使われているか確定するまで実装方式（読み取り部分）は決められない。ここが最優先。

---

## 3. 移植する中核ロジック（macOS版と完全に同じ）

認証情報の形式・API仕様は**OS非依存**。macOS版のロジックをそのままC#に翻訳すればよい。

### 3-1. トークンのパース（JSON構造）
```
root
 └ claudeAiOauth
     ├ accessToken : string   ← これを使う
     ├ scopes      : string[] ← "user:profile" を含む必要あり（無ければ使用量取得不可）
     └ expiresAt   : number   ← エポック「ミリ秒」。現在時刻超過なら期限切れ
```
- `claudeAiOauth` が無く `mcpOAuth` だけの場合は「再ログインが必要」エラー扱い（Claude Code 2.1.x の一部環境）。
- refresh は**やらない**。Claude Code本体に任せる（自前でrotateすると本体側のrefresh tokenが無効化される）。

### 3-2. API呼び出し
`GET https://api.anthropic.com/api/oauth/usage`

必須ヘッダ：
| ヘッダ | 値 |
|---|---|
| `Authorization` | `Bearer <accessToken>` |
| `anthropic-beta` | `oauth-2025-04-20` |
| `User-Agent` | `claude-code/<version>`（**必須**。無いと厳しい429バケット行き） |
| `Accept` / `Content-Type` | `application/json` |

ステータス処理（macOS版 `UsageService.swift` と同じ）：
- `200` → パースして表示
- `401` → 認証エラー（再ログイン案内）
- `403` → スコープ不足
- `429` → `Retry-After` 秒（無ければ **300秒**）クールダウン
- その他 → HTTPエラー表示

### 3-3. レスポンス（`UsageParser` 相当）
- `five_hour` / `seven_day` / `seven_day_opus` / `seven_day_sonnet` に `{utilization: 0-100, resets_at: ISO8601}`
- 新形式 `limits[]`（`kind:"weekly_scoped"`, `percent`, `scope.model.display_name` 例:"Fable"）+ `extra_usage`
- 詳細な実仕様はメモ `claude-oauth-usage-api.md` を参照。

### 3-4. User-Agent用のCLIバージョン検出
- macOS版は `claude --version` を実行して `\d+\.\d+\.\d+` を抽出、失敗時は `2.1.0` 固定。
- Windowsでも同様に `claude --version`（`claude.cmd`／PATH経由）を実行して抽出。取れなければ固定値でよい。

---

## 4. UI・OS機能マッピング（macOS → Windows）

| macOS版のパーツ | ファイル | Windows版での置き換え |
|---|---|---|
| メニューバー常駐 | `StatusBar/StatusItemController.swift` | `NotifyIcon`（システムトレイ） |
| バーに使用量%を文字表示 | `StatusBar/StatusLabelView.swift` | **トレイは文字表示不可** → %を焼き込んだ動的アイコン(Bitmap)を生成 or ツールチップ表示（§6参照） |
| ポップアップパネル | `Panel/PanelController.swift`, `PanelViews.swift` | ボーダーレス`Form`をトレイ左クリックで表示 |
| ゲージ描画 | `Components/UsageGaugeView.swift` | `System.Drawing`（GDI+）で自前描画、または WPF |
| 設定画面 | `Settings/SettingsWindow.swift` | 設定`Form` |
| 設定の保存 | `Services/SettingsStore.swift`（UserDefaults） | `%APPDATA%\ClaudeBar\settings.json` |
| 使用量履歴/予測 | `Services/UsageHistory.swift` | 同ロジックをC#へ翻訳（JSONで永続化） |
| 通知 | `Services/NotificationService.swift` | `NotifyIcon.ShowBalloonTip` or トースト通知 |
| スリープ復帰で再取得 | `NSWorkspace.didWakeNotification` | `SystemEvents.PowerModeChanged`（Resume） |
| ログイン項目（自動起動） | `Services/LoginHelper.swift` | レジストリ `HKCU\...\Run` or スタートアップフォルダ |
| 自動アップデート | `Services/UpdaterService.swift`（Sparkle系, `docs/appcast.xml`） | **Velopack**（推奨）or 手動DL。v1では省略も可 |

---

## 5. 実装ステップ順序（推奨）

1. **認証情報の在り処を確定**（§2）← ここが通らなければ始まらない
2. コンソールアプリで「トークン取得 → API叩く → JSONを標準出力」まで通す（UIなしで疎通確認）
3. `NotifyIcon` でトレイ常駐 + 右クリックメニュー（終了・設定・再取得）
4. ポップアップパネル（トレイ左クリック）で使用量を表示
5. 定期ポーリング（設定間隔）+ スリープ復帰時再取得
6. 設定の永続化、自動起動
7. 通知（しきい値）
8. アイコンへの%焼き込み（§6）
9. 配布：単一exe化 → Authenticode署名（§7）
10. （任意）自動アップデート

---

## 6. Windows特有の注意点（UX）

- **トレイにテキストを直接出せない**：macOS版はバーに「45%」等を文字で出しているが、Windowsのトレイはアイコン画像のみ。
  → %を描画したBitmapを動的生成して `NotifyIcon.Icon` に差し替える、が定番。手軽に済ませるならツールチップ（`NotifyIcon.Text`）に出す。
- **トレイアイコンは既定で折りたたまれる**：ユーザーが手動でタスクバーにピン留めしないと見えない。初回に案内が必要。
- **DPIスケーリング**：高DPI環境でアイコン・パネルがぼやけないよう `app.manifest` で PerMonitorV2 を有効化。

---

## 7. 配布・コード署名

- **Authenticode署名が実質必須**。無署名だと起動時に **SmartScreen** の警告が出て信用されない。
- 証明書の選択肢：
  - **Azure Trusted Signing**（新しい・比較的安価・クラウド署名）← 今なら第一候補
  - OV証明書（安いがSmartScreen評価の蓄積が必要）
  - EV証明書（即時にSmartScreen信頼・ハードウェアトークン・高価）
- macOSの「公証」に相当する手順はWindowsには無いが、代わりにこの署名+評価蓄積が必要。

---

## 8. 権利面のリスク（macOSと共通・再掲）

- 「Claude」商標と**非公開API**依存の問題は、OSに関わらず残る。
- Windows版を出すことで露出が増える点は意識する。まずは無料配布が無難。

---

## 参照

- API実仕様メモ: `claude-oauth-usage-api.md`（メモリ内 / type: reference）
- 移植元コード（読み取り・API）:
  - `Sources/ClaudeBar/Services/CredentialsStore.swift`
  - `Sources/ClaudeBar/Services/UsageService.swift`
  - `Sources/ClaudeBar/Services/UsageParser.swift`
- 設計全体: `DESIGN.md`
