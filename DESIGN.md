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

## 状態機械（PanelMode + bubbleActive）

ウィンドウは2枚。パネル（attached/floating）とバブルは**独立して共存できる**。

| 状態 | ウィンドウ | 遷移 |
|---|---|---|
| `attached` | メニューバー直下、外側クリックで閉じる、level=.popUpMenu | グリップドラッグ30pt超 → `floating`（ぷるんっ） |
| `floating` | 引き剥がしたパネル。背景ドラッグで移動可、常時最前面 | ×ボタン → 閉じて`attached`へ / メニューバークリック → `attached`へ復帰 |
| `bubbleActive` | **専用の150pt透明ウィンドウ**の中でアセンブリ（ガラス+内容76-106pt）だけが浮遊 | 🫧ボタン（トグル: 常時グレー地・ONでアクセント色）でON/OFF / メニューバー付近へドラッグ → 吸着して消える / 3連打 or 100% → 破裂 → リセット後に復活 |

パネルの `NSPanel` は `UsagePanelView`、バブルの `NSPanel` は `BubbleRootView` を常時ホストする
（旧設計の「1枚のウィンドウをクローム変形して使い回す」方式は廃止）。

### バブルのアニメーション（60fps保証の要）

- 毎フレームのウィンドウ移動はmacOS 14+でvsync同期のウィンドウサーバ往復となりカクつくため、**ウィンドウは動かさない**
- 浮遊は周期の異なる正弦波4本（easeInEaseOut・autoreverse・無限リピート・加算合成）を**レンダーサーバに常駐**させる方式。アプリのメインスレッドが詰まっても滑らか、繋ぎ目も存在しない
- 現在位置の取得は `layer.presentation()`（macOSのlayer-backed viewはanchorPoint(0,0)なのでposition=frame.origin）
- クリック透過はカーソル位置の80msポーリングで `ignoresMouseEvents` を切り替え。クリック=展開/ドラッグ=移動はAppKitローカルモニタで判定（SwiftUIのDragGestureは非アクティブ化パネルで不安定）
- App Nap対策として浮遊中は `ProcessInfo.beginActivity` を保持

### ファイル分割

- `PanelController.swift` — コア（ウィンドウ生成・attached・tear-off・表示/非表示・監視）
- `PanelController+Bubble.swift` — バブル固有（クローム・浮遊・マウス操作・破裂・復活・吸着）
- `Services/LoginHelper.swift` — `claude /login` 誘導（自前ログインは規約上禁止のため）

### メニューバーアイテム（純正準拠の要点・2026-07調査反映）

- **フォント**: `NSFont.menuBarFont(ofSize: 0)` + monospacedDigit。純正はRegular・約13-14ptで、
  アクセシビリティの「メニューバーを大きく」にも自動追従する。systemFontの手指定は使わない
- **クリック**: NSStatusBarButtonにイベントを渡すとレガシーな黒押下ハイライトが出る
  （highlightsBy=[]でも抑止不可）ため、透明なStatusClickCatcherViewでmouseDown/rightMouseDownを
  直接受けてボタンのトラッキングを迂回する。開くのはmouseDown（純正と同じ）
- **展開時ハイライト**: 純正は「淡い外観追従オーバーレイのフルハイトピル・文字色は反転しない」
  （拡大実測 約22%）。SwiftUIのCapsuleで自前描画し、state.menuHighlightedで点灯。
  ※調査結論: Tahoeでは isHighlighted だけで純正カプセルが描かれるが、それは
  「ボタンをカスタムビューで覆っていない」場合のみ。ホスティングで覆う本アプリでは
  レガシー黒ピルが出るため自前描画が正解（fluid-menu-bar-extra等の実装調査に基づく）
- **フルスクリーン対応**: 開閉時に beginMenuTracking / endMenuTracking の
  DistributedNotificationを送出（純正メニューと同じくフルスクリーンでもバーが維持される）
- **開閉**: 完全同期・フェードなし。表示前に layoutSubtreeIfNeeded + displayIfNeeded で
  初回フレームを完成させる。閉じは即時orderOut（フェードはレースの温床のため全廃）
- **余白**: Tahoeはシステム側がNSStatusItemSelectionPaddingを付与するため自前余白は控えめ(6pt)

### ガラス描画（最終形）

- NSGlassEffectViewは不使用（contentView機構の内部Auto Layoutとautoresizingの相互作用で
  ウィンドウ/ガラスが内容サイズへ強制収縮する多段バグの温床だった）
- **SwiftUIの .glassEffect(.regular.tint(windowBackgroundColor 45%)) が内容にピッタリ描く**。
  透明ボーダレスウィンドウでも背後サンプリングが効くことは実証済み
- ウィンドウは固定サイズ（パネル300x460 / バブル150）でリサイズしない。
  内容は上詰め、余白は完全透明。hosting.sizingOptions = [] は必須

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
