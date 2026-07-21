# ClaudeBar 設計書

## 全体像

```
┌──────────────────────── メニューバー ────────────────────────┐
│                                              42% ✳  ← クリック │
└──────────────────────────────────────────────┬───────────────┘
                                    ┌──────────▼──────────┐
                                    │  ══ (グリップ)       │  attached
                                    │ ✳ Claude 使用量      │  (Liquid Glass)
                                    │ 現在のセッション  34% │
                                    │ ▓▓▓▓▓░░░░░░░░░      │
                                    │ 週間制限             │
                                    │  すべてのモデル  12%  │
                                    │  Fable          5%  │
                                    │ 12:34更新  ↻ 🫧 ⏻   │
                                    └─────────────────────┘
                                グリップをドラッグして引き剥がす
                                       ↓ ぷるんっ (ジェリー変形+ハプティクス)
                                    ╭─────╮
                                    │ ✳    │  bubble: ぷかぷか浮遊・常時最前面
                                    │ 34%  │  クリック→floatingパネルに展開
                                    ╰─────╯  100%到達→💥割れる(Pop音+飛沫)
```

## 状態機械（PanelMode）

| 状態 | ウィンドウ | 遷移 |
|---|---|---|
| `attached` | メニューバー直下、外側クリックで閉じる、level=.popUpMenu | グリップドラッグ30pt超 or 🫧ボタン → `bubble` |
| `bubble` | 76pt円形、常時最前面(.floating)、全Space表示、30fpsで正弦波の揺れ | クリック → `floating` / 右クリックメニュー → attached復帰 / 100% → 割れてattachedへ |
| `floating` | 展開パネル、背景ドラッグで移動可 | ×ボタン → `attached`（閉じる） / 🫧 → `bubble` |

1つの `NSPanel` を使い回し、フレームと `NSGlassEffectView.cornerRadius` をアニメーションで変形させる。
SwiftUI側は `state.mode` で `UsagePanelView` / `BubbleView` を切り替え。

## モジュール構成

```
Sources/ClaudeBar/
├── Main.swift                  # NSApplication起動・依存の組み立て（.accessory）
├── AppState.swift              # @Observable 単一状態（usage/mode/isActive/detachBounce）
├── Services/
│   ├── CredentialsStore.swift  # Keychain「Claude Code-credentials」読み取り（読み取り専用）
│   ├── UsageService.swift      # /api/oauth/usage ポーリング（120s、429→5分クールダウン）
│   └── ActivityMonitor.swift   # FSEvents監視 → isActive（ロゴアニメ）
├── StatusBar/
│   ├── StatusItemController.swift  # NSStatusItem + PassthroughHostingView
│   └── StatusLabelView.swift       # 「42% ✳」
├── Panel/
│   ├── PanelController.swift   # ウィンドウ状態機械・tear-off検知・ぷかぷか・割れ演出
│   └── PanelViews.swift        # PanelRootView / UsagePanelView / BubbleView / PopBurstView
└── Components/
    ├── ClaudeLogoView.swift    # サンバーストShape + 回転/脈動アニメ
    ├── UsageGaugeView.swift    # ゲージ行（80%で橙、95%で赤）
    └── PassthroughHostingView.swift
```

## キーとなる実装判断

1. **`MenuBarExtra`ではなく`NSStatusItem`+`NSPanel`**
   tear-off・自由なウィンドウ変形・ぷかぷかアニメは`MenuBarExtra`では不可能。

2. **Liquid Glassは`NSGlassEffectView`（AppKit）**
   ボーダーレス透明ウィンドウでウィンドウ背後のコンテンツをサンプリングするにはAppKit層のガラスが必要。
   SwiftUIの`.glassEffect`はウィンドウ内合成のため単独では背後が透けない。

3. **tear-off検知は`WindowDragGesture`+`windowDidMove`**
   グリップに`WindowDragGesture`（ネイティブのウィンドウドラッグ）を貼り、
   デリゲートの`windowDidMove`でattached位置から30pt超えたら`becomeBubble()`。
   `isProgrammaticMove`フラグで自前の移動と区別する。

4. **ぷるんっ = `keyframeAnimator` の非対称スケール**
   `detachBounce`をトリガーに sx/sy を逆位相で振るジェリー変形 + `NSHapticFeedback(.levelChange)`。

5. **ぷかぷか = Timer(30fps)でウィンドウ原点を正弦波移動**
   複数周波数の合成で有機的な揺れ。ドラッグ中（`NSEvent.pressedMouseButtons != 0`）は停止し、
   `windowDidMove`でユーザーのドラッグ後の位置に揺れの基準点を追従。

6. **割れる演出は別ウィンドウ**
   バブルウィンドウは76ptしかなく飛沫がクリップされるため、
   220ptの`ignoresMouseEvents`透明ウィンドウを重ねて飛沫を飛ばす。Pop音は`NSSound(named: "Pop")`。

7. **認証はClaude Codeのトークンを読み取り専用で流用**
   refresh tokenのrotateはClaude Code本体に任せる（二重refreshで互いに無効化するため）。
   `user:profile`スコープ必須 / `mcpOAuth`のみのKeychainエントリ（2.1.x）も検出してエラー表示。

8. **API仕様**（実地調査済み・非公開API）
   - `GET https://api.anthropic.com/api/oauth/usage`
   - 必須ヘッダ: `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/<version>`（無いと429バケット行き）
   - `utilization`は**0-100のパーセント値そのまま**。`five_hour` / `seven_day` / `seven_day_opus`
   - 新形式`limits[]`: `{kind: "weekly_scoped", percent, scope.model.display_name: "Fable"}` → Fable行のラベルはここから動的に取得

## v2で実装済みの追加機能

- 80%/95%到達時の通知センター通知（`NotificationService`・.app起動時のみ）
- ログイン時自動起動（`SMAppService`・設定画面から）
- ペース予測（`UsageHistory`: 週間%を蓄積→直近6hを最小二乗法で外挿）
- `extra_usage`（追加クレジット消費額）の表示
- バブルが割れた後、セッションリセット時刻+90秒に「ぽわんっ」と自動復活
- バブルをメニューバー付近へドラッグ→吸着して戻る（ドラッグ終了時に判定）
- ステータスアイコンの右クリックメニュー / 設定ウィンドウ / アプリアイコン自動生成
- メニューバー%のしきい値カラー（80%橙・95%赤）+ numericText遷移
- パネル高さのコンテンツ追従（onGeometryChange→上端固定でリサイズ）
- デバッグブリッジ（CLAUDEBAR_DEBUG/FAKE/CMDFILE）でUIをスクリプト操作可能
- UsageParser/CredentialsStoreのユニットテスト（swift test・9件）

## 実機検証済み（2026-07-22）

- メニューバー表示（NSButtonの固有幅27ptに潰される問題を実測幅→length反映で修正）
- パネル/バブル/展開/100%破裂/破裂後の状態遷移をスクリーンショットで目視確認
- hideフェードとshowの競合を世代カウンタで修正

## 今後のアイデア（未実装）

- バブルのクリック透過モード（作業の邪魔をしない幽霊バブル）
- 複数ディスプレイでのバブル位置記憶
