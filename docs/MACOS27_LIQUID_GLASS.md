# macOS 27 (Golden Gate) と ClaudeBar — 動作確認と Liquid Glass 調査

調査日: 2026-09-15 / 対象: ClaudeBar v1.6.1（配布版）+ main (cb9efbf)
環境: macOS 27.0 (26A428) / Xcode 26.6 (17F113, **macOS 26.5 SDK**) / Swift 6.3.3 / MacBook Pro (Apple Silicon)

## 0. 結論

| 項目 | 結果 |
| --- | --- |
| クリーンビルド・テスト | OK（警告1件は既存の Sendable 警告、OS 無関係） |
| 配布版 v1.6.1 の常駐 | 起動〜6分で CPU 0%、RSS 64MB。クラッシュレポート・システムログのエラーなし |
| メニューバー表示 | 「8% ✳」正常描画 |
| ステータスアイテムの実クリック（CGEvent） | パネルがトグルで開閉する。`StatusClickCatcherView.mouseDown` 経路は 27 でも有効 |
| トークン取得（`security find-generic-password -w`） | ダイアログなしで取得。`user:profile` スコープあり・有効期限内 |
| 使用量 API | 起動後に取得済み（メニューバーの 8% は起動後のフェッチ結果。AppState は永続化しない） |
| Sparkle appcast | HTTP 200（0.27s）。1.6.1 が最新として配信中 |
| **Liquid Glass のバブル** | **黒背景で暗くならない（自動反転が消えた）。OS 側の仕様変更で、アプリのコード起因ではない** |
| メニューバー構造 | 27 で「1アイテム=1ウィンドウ」から「メニューバー全体=1ウィンドウ」へ。自アプリの `button.window` は従来どおり取得でき、パネルの位置決めは正常 |

## 1. 動作確認の詳細

- ビルド: `swift package clean && swift build` 10.9s、`swift test` 9/9 成功。
- 常駐プロセス: `/Applications/ClaudeBar.app` (pid 1752) が再起動後に自動起動、`log show --predicate 'process == "ClaudeBar"'` にエラー・fault なし。`~/Library/Logs/DiagnosticReports` に ClaudeBar のクラッシュなし。
- クリック: System Events の `click menu bar item` は **反応しない**（AXPress はボタンの action を呼ぶだけで、`mouseDown` を直接受ける Catcher には届かない）。CGEvent で実マウスクリックを合成すると開閉する。デバッグビルドの `state` でも `visible: true` を確認。
- デバッグビルド（`CLAUDEBAR_DEBUG=1 CLAUDEBAR_FAKE=1`）でパネル・バブルの表示、`bubble`/`tobubble`/`legacy` コマンドの動作を確認。
- 認証: `~/.claude/.credentials.json` は無く、Keychain 項目「Claude Code-credentials」のみ。属性照会（mdat）と `security` CLI の両方が無音で成功。
- Sparkle: 2.9.4 を pin。最新 2.10.0（2026-09-13）に「Fix re-applying file system compression for delta updates on macOS 27」があるが、ClaudeBar の appcast はデルタ未使用（`sparkle:deltas` 0 件）なので影響なし。2.10.0 は最低 macOS 12（ClaudeBar は 14 なので問題なし）。

### 未確認（手動で見てほしい点）
- 通知の許可とログイン項目（OS 更新で TCC が初期化されることがある）。システム設定 > 通知 / 一般 > ログイン項目。
- Liquid Glass スライダーの現在位置（システム設定 > 外観 > Liquid Glass）。`defaults` にキーが書かれておらず既定（中央）と推定。左端（クリア寄り）で自動反転が戻るかは未検証。
- サブディスプレイでの開閉。合成クリックでは「約2秒後に閉じる」ように見えた場面があったが、同時にユーザー操作があったため切り分け不能。

## 2. 実測: macOS 27 での Liquid Glass の振る舞い

単体プローブ（60pt / 100pt の円に `.glassEffect(.regular, in: Circle())`、文字は `.primary`）を黒/白の下地に載せて撮影（`docs/screenshots/macos27-glass-probe.png`）。

| アプリ外観 | 下地 | 直径 | 結果 |
| --- | --- | --- | --- |
| Light | 黒 | 60 | 灰色の明るいガラス + **黒文字**（暗くならない） |
| Light | 白 | 60 | 明るいガラス + 黒文字 |
| Dark | 黒 | 60 | ほぼ黒のガラス + 白文字 |
| Dark | 白 | 60 | 薄灰のガラス + **白文字**（コントラスト低） |
| Light | 黒 | 100 | 60 と同じ |
| Dark | 白 | 100 | 60 と同じ |

- **ガラスと文字色は「背景の明暗」ではなく「アプリ/システムの外観（Light/Dark）」に追従する。**
- macOS 26 で実測していた「64pt 以下は背景に応じて light/dark を自動反転、65pt 以上は外観追従」の境目は 27 では観測されない（両方とも外観追従）。
- ClaudeBar のバブル（`SingleBubbleGlass`、content 側に `.regular`）も同じ: 黒背景でも Light 外観なら白っぽいガラス + 黒文字（`docs/screenshots/macos27-bubble-black-white.png`）。ユーザー報告「黒い背景に行った時に暗くなる挙動が無くなってる」と一致。
- パネル背景は `.menu` マテリアル（NSVisualEffectView）なので影響なし。ホバー HUD（約 200×100pt）はダーク外観 × 白背景でも暗いガラスに描かれ可読（大きい要素は外観側へ寄る）。
- **`.glassEffect(.regular.tint(...))` は 27 で効かない**: `.tint(.red)` でも赤くならず、`Color.black.opacity(0.6)` / `windowBackgroundColor.opacity(0.6)` とも球内輝度が不変（60・140pt で実測。26 ではパネルのティント 20% で輝度差が出ていた）。
- サイズによる違いは「不連続な 64/65pt の境目」ではなく緩やかな傾向のみ: ダーク × 白の球内輝度は 60pt=180 / 66pt=177 / 80pt=154 / 140pt=139。

## 3. macOS 27 の Liquid Glass — 公式・一次情報

### 3.1 ユーザー設定: Liquid Glass スライダー
- システム設定 > 外観（Appearance）> **Liquid Glass** スライダー。左=よりクリア（背景が透ける）、右=よりティント（ほぼ不透明に「曇る」）、**既定は中央**。プレビュー付き。iOS 26.1 の「クリア / 色合い（Tinted）」2択を連続値にしたもの。
- WWDC26「What's new in SwiftUI」(269): 「Liquid Glass has a refined look and **automatically responds to the new Liquid Glass slider to adjust its tint**」— アプリ側の対応不要で自動追従。
- スライダーが変えるのはメニュー・コントロールセンター・通知センター・Spotlight・ツールバー・サイドバーのティント量で、**メニューバーと Dock の透明度は変わらない**（Badgeify / MacStories）。
- スライダー値を読む公開 API は見つからない。HIG は「The appearance of these variants can differ in response to certain system settings, like if people choose a preferred look for Liquid Glass in their device's settings, or turn on accessibility settings that reduce transparency or increase contrast」とだけ述べる。既存の `NSWorkspace.accessibilityDisplayShouldReduceTransparency` / `IncreaseContrast` は従来どおり。

### 3.2 自動で変わる見た目（再ビルド不要）
- 26 で Liquid Glass を採用したアプリは 27 で自動的に更新後の見た目になる（WWDC26 269 / 289）。
- 変更点（MacRumors / MacStories / Six Colors）: 背後の複雑なコンテンツをより強くぼかす（diffuse）、**要素の縁が暗くなりハイライトが明るくなる**（層の分離）、コンテンツがバーの下をスクロールすると連続した不透明バーが出る、ウィンドウ角の半径が小さめで統一、サイドバーがウィンドウ端まで伸びる、信号機ボタンにガラスのシェーディング。
- 26.4 の前史: 「Tinted 設定のとき、ガラスが背後のコンテンツではなく **ユーザーの Light/Dark 設定を尊重する**ようになった」（anderegg.ca 2026-03-29）。それ以前は背後の明暗で Light/Dark を行き来してチラついていた。27 ではこの方針がスライダーに統合され、既定でも外観追従になっている（本機実測）。

### 3.3 API（SDK 26.5 のインターフェイスと Apple Developer Documentation で確認）
- SwiftUI `Glass`: `.regular` / `.clear` / `.identity` + `.tint(_:)` / `.interactive(_:)` のまま。**27 での新変種・新パラメータは無い。** `GlassButtonStyle` (`.glass`) は 26.1 で追加済み。
- AppKit `NSGlassEffectView`: `contentView` / `cornerRadius` / `tintColor` / `style` / `effectIsInteractive`、`NSGlassEffectContainerView`: `contentView` / `spacing`。27 での追加なし。
- 27 で新規（macOS 27 SDK = Xcode 27 が必要。本機は Xcode 26.6 / SDK 26.5 なので未使用）:
  - `NSStatusItem.expandedInterfaceDelegate` / `NSStatusItemExpandedInterfaceDelegate` / `NSStatusItemExpandedInterfaceSession` — ステータスアイテム直下にカスタムウィンドウ（NSPanel 等）を出すアプリ向け。「When a status item shows its window, AppKit needs to know when that UI is active, so that keyboard focus can behave correctly」（WWDC26 289）。キーボードでのメニューバー/ステータスアイテム移動に対応する。ClaudeBar のパネルはまさにこの用途。
  - `NSViewCornerConfiguration` / `.containerConcentric` — コンテナと同心の角丸。
  - SwiftUI `@Environment(\.appearsActive)` — ウィンドウ非アクティブ時の減光に合わせる。
  - macOS 27 リリースノート: `.glass` / `.glassProminent` ボタンのツールバー外ホバー表示修正、`NSSegmentedCell` の Liquid Glass 描画位置修正、`NSTitlebarAccessoryViewController` が境界外描画可（27 リンク時）、メニュー項目の SF Symbols 画像を既定で非表示（NSMenu / SwiftUI とも。ClaudeBar の右クリックメニューは画像なしなので影響なし）。
- WWDC26 289「Modernize your AppKit app」: `mouseDown` オーバーライドとトラッキングループを **ジェスチャ認識器 / control events に置き換える**よう推奨（廃止ではない。`StatusClickCatcherView` の `mouseDown` は 27 で動作確認済み）。ステータスアイテムはボタンに target/action を付けるとキーボード操作（Return）で発火する。

### 3.4 HIG（Materials）の要点
- Liquid Glass はコントロール/ナビゲーション層専用。コンテンツ層には使わない。カスタムコントロールでの使用は控えめに。
- `.regular`: 「blurs and adjusts the luminosity of background content to maintain legibility」。`.clear`: 高透過、写真・動画の上専用で、明るい下地では 35% の暗幕を敷く。
- 「Choose materials based on semantic meaning… system settings can change its appearance」。素材の見た目の色で選ばない。

### 3.5 メニューバーの構造変更（27）
- メニューバー全体が **1つのウィンドウ**として描画される（従来は各ステータスアイテムが独立した小ウィンドウ）。Bartender / Ice / Thaw / Barbee 等のメニューバー管理アプリはこれで動作不能になった。
- ノッチで溢れたアイテムは、標準の **オーバーフロー（>）ボタン**で展開/折りたたみ。ClaudeBar のアイテムがオーバーフローに入ったときのパネル位置は未検証。
- 自アプリの `NSStatusItem.button.window`（NSStatusBarWindow）は 27 でも存在し、`buttonScreenFrame` によるパネル位置決めは正常（実測: item 58.5×16pt、statusWindow 75×30pt）。

## 4. ClaudeBar への影響と対応

1. **バブルの明暗 → 対応済み（2026-09-15、`BubbleAppearanceFilm`）**
   - 前提だった「≤64pt の `.regular` は背景で自動反転し、文字も一緒に反転する」が 27 で崩れた。Light 外観 × 黒背景では「明るい球 + 黒文字」（読めるが暗くならない）、**Dark 外観 × 白背景では「薄灰の球 + 白文字」で読みにくい**。本機は外観の自動切替（AppleInterfaceStyleSwitchesAutomatically=1）なので夜間に後者になる。
   - 採用: 27 の Liquid Glass 経路だけ、ガラスの上（content 側）に外観と同じ側の色の膜を重ねる＝システムの「Tinted」相当。ダークは `Color(white: 0.18)` を乗算 60%、ライトは `Color(white: 0.93)` をスクリーン 60%。外周は半径 86% から 0 へフェードし、27 のガラスが持つ縁の暗化と二重にならないようにする（一様に掛けると太い輪郭線に見えた）。
   - 効果（60pt・球内輝度）: ダーク × 白 181 → 122、ライト × 黒 129 → 158。同じ側の背景（ダーク × 黒 / ライト × 白）はほぼ無変化。3つ表示も同じ膜。
   - ガラス自体は Liquid Glass スライダーに追従するので、膜はその上に一定量だけ足される。スライダー値を読む API は無いため固定量（`CLAUDEBAR_FILM_D` / `_L` / `_EDGE` で調整可）。
   - 見送り: `.regular.tint(...)`（27 で無効）、背景輝度の自前推定（画面収録権限が要る）、球の大径化（80pt でも 154 で不足）。
   - 26 の経路（自動反転）と旧 OS の経路（`BubbleTextPlate`）は変更なし。`CLAUDEBAR_FORCE_LEGACY=1 swift test` と旧 OS 表示の撮影で膜が出ないことを確認済み。
2. **`NSStatusItem.expandedInterfaceDelegate` の採用**（任意）: Xcode 27 に上げてから `#available(macOS 27, *)` で採用すると、キーボードナビゲーションとフォーカス扱いが純正メニュー相当になる。
3. **Sparkle 2.10.0 への更新**（任意・低優先）: 27 関連の修正はデルタ更新のみ。
4. **CI**: `macos-26` ランナー + Xcode 26.x で引き続きビルド可。27 SDK の API を使う段階で Xcode 27 ランナーが必要。
5. **`mouseDown` オーバーライド**: 動作するが、Apple は control events / gesture recognizer への移行を推奨。次に触るときに検討。

## 5. 出典
- Apple: macOS 27 Release Notes https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes
- Apple: Glass https://developer.apple.com/documentation/swiftui/glass / glassEffect(_:in:) https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)
- Apple: NSGlassEffectView https://developer.apple.com/documentation/appkit/nsglasseffectview / NSGlassEffectContainerView https://developer.apple.com/documentation/appkit/nsglasseffectcontainerview
- Apple: NSStatusItem.expandedInterfaceDelegate https://developer.apple.com/documentation/appkit/nsstatusitem/expandedinterfacedelegate
- Apple: Adopting Liquid Glass https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- Apple HIG: Materials https://developer.apple.com/design/human-interface-guidelines/materials
- WWDC26 269 What's new in SwiftUI https://developer.apple.com/videos/play/wwdc2026/269/
- WWDC26 289 Modernize your AppKit app https://developer.apple.com/videos/play/wwdc2026/289/
- MacRumors: How Liquid Glass Is Changing in iOS 27 https://www.macrumors.com/2026/06/10/how-liquid-glass-is-changing-in-ios-27/
- MacRumors: iOS 27 Tone Down Liquid Glass Transparency https://www.macrumors.com/how-to/ios-27-tone-down-liquid-glass-transparency/
- MacStories: macOS 27 Review (p.2) https://www.macstories.net/stories/macos-27-the-macstories-review/2/
- Six Colors: macOS 27 Golden Gate Review https://sixcolors.com/post/2026/09/macos-27-golden-gate-review-bridging-the-tahoe-gap/
- AppleInsider: Don't get excited for big Liquid Glass changes in macOS 27 https://appleinsider.com/articles/26/06/09/dont-get-excited-for-big-liquid-glass-changes-in-macos-27-because-they-arent-there
- iDownloadBlog: How to change the Liquid Glass level https://www.idownloadblog.com/2026/06/18/adjust-liquid-glass-ios-macos/
- anderegg.ca: Liquid Glass updates in 26.4 https://anderegg.ca/2026/03/29/liquid-glass-updates-in-264
- Badgeify: macOS 27 menu bar changes https://badgeify.app/macos-27-golden-gate-menu-bar-changes/
- BetterTouchTool community: macOS 27 menu bar management broken https://community.folivora.ai/t/macos-27-golden-gate-menu-bar-management-broken-solutions-ice-thaw-bartender-barbee-etc/47232
- Use Your Loaf: WWDC 2026 Viewing Guide https://useyourloaf.com/blog/wwdc-2026-viewing-guide/
- Sparkle 2.10.0 release https://github.com/sparkle-project/Sparkle/releases
- Apple Developer Forums: NSGlassEffectView issue on macOS 26.2 https://developer.apple.com/forums/thread/810314
