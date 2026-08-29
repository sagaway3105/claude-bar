# Liquid Glass 仕様メモ（macOS 26 / 2026-08-28 調査）

ClaudeBar のバブルとパネルは Liquid Glass（`glassEffect` / `NSGlassEffectView`）で描いている。
その挙動でハマった点を、**Apple の一次情報（公式ドキュメント・HIG・WWDC）で裏を取った結果**と、
**公式には書かれておらず実測でしか分からなかった点**を分けて記録する。

実装側の「どう描いているか」は [BUBBLE_RENDERING.md](BUBBLE_RENDERING.md) にある。こちらは「仕様の根拠」。

---

## 0. 30秒サマリ

| 論点 | 結論 | 根拠 |
| --- | --- | --- |
| `.regular` は背景に適応するか | **する**。輝度を調整して可読性を保つ | 公式 |
| **サイズで扱いが変わるか** | **変わる。小さい＝より透明＋light/darkを自動反転／大きい＝より不透明＋反転しない** | 公式（数値は非公開） |
| その境目 | **直径64pt と 65pt の間**（不連続に切り替わる） | **実測のみ** |
| 反転時に文字も反転するか | **する**。ただし**ガラスの content に入れて `.primary` で描いた場合** | 挙動は公式、条件は実測 |
| 背景の明るさを自前で測れるか | **測れない**（画面収録権限が要る）。測る必要も無い | — |
| 複数のガラスを並べるとき | 公式は `GlassEffectContainer` 必須（適応の統一・サンプリング共有・性能） | 公式 |
| ガラスに `opacity` を掛ける | **禁止**（公式に明記） | 公式 |
| ガラスの上にガラス | **禁止**（公式に明記） | 公式 |
| `.regular` と `.clear` の混在 | **禁止**（公式に明記） | 公式 |

---

## 1. `.regular` / `.clear` の定義と「適応」

### 公式に書かれていること

- `Glass` は「Liquid Glass マテリアルの構成を定義する構造体」。型プロパティは `regular` / `clear` / `identity`。
  https://developer.apple.com/documentation/swiftui/glass
- **`.regular`**: 「背景コンテンツをぼかし、**輝度（luminosity）を調整して**テキストや前景要素の可読性を保つ」「Most system components use this variant」
  https://developer.apple.com/design/human-interface-guidelines/materials
  WWDC219: 「Regular… provides legibility regardless of context. **It works in any size, over any content** and anything can be placed on top of it.」
- **`.clear`**: 「**adaptive behaviors を持たない**」「恒久的により透明」。可読性のために自前の dimming layer が必要で、HIG は明るいコンテンツ上で「35% opacity の暗い層」を指定。
  https://developer.apple.com/documentation/swiftui/glass/clear
- **`.identity`**: 「適用してもグラス効果が無いかのようにコンテンツが変化しない」
  https://developer.apple.com/documentation/swiftui/glass/identity
- **適応の入力として公式に挙がっているもの**:
  1. 背後のコンテンツ（「each layer continuously adapts based on what's behind it」）
  2. **サイズ**（「adaptive to both its size and its environment」）
  3. 外観設定（userInterfaceStyle）
  4. 周囲のアンビエント（「light from colorful content nearby can subtly spill onto its surface」）
  5. **ウィンドウのフォーカス状態**（「when a window loses focus on the Mac or iPad, Liquid Glass shifts its appearance and visually recedes」）
  6. アクセシビリティ設定（Reduce Transparency / Increase Contrast / Reduce Motion）

### 公式に書かれていないこと

- 適応判定に使う輝度の**計算方法・サンプル領域・閾値**
- 反転にヒステリシスがあるか、アニメーションするか
- **適応を強制・無効化する公開API**（`Glass` に該当プロパティは無い）

---

## 2. サイズによる扱いの差 ← 今回の核心

### 公式に書かれていること

WWDC25 セッション284「Build a UIKit app with the new design」（21:30）:

> **Glass adapts the appearance based on its size. A larger size is more opaque. A smaller size is clearer, and switches between light and dark mode automatically, to increase contrast.**

WWDC25 セッション219「Meet Liquid Glass」（15:16）:

> **Small elements like navbars and tabbars, constantly adapt their appearance depending on what's behind them. They also flip from light to dark based on the background… Bigger elements, like menus or sidebars also adapt based on context, but they don't flip from light to dark. Their surface area is too big and transitions like these would be distracting.**

HIG「Color」:

> For smaller elements like toolbars and tab bars, the system can adapt Liquid Glass between a **light and dark appearance in response to the underlying content**. By default, **symbols and text on these elements follow a monochromatic color scheme, becoming darker when the underlying content is light**, and lighter when it's dark. Liquid Glass appears more opaque in larger elements like sidebars to preserve legibility over complex backgrounds.

HIG「Materials」は役割ベースの区分も置いている（pt数ではない）:

> Liquid Glass forms a distinct functional layer for controls and navigation elements — like tab bars and sidebars — that floats above the content layer. / **Don't use Liquid Glass in the content layer.**

### 公式に書かれていないこと ＝ 実測で埋めた部分

**具体的な閾値は一切非公開。** ClaudeBar で刻んで測った結果（ダーク外観・白背景の上・球の中の輝度 0-255）:

| 直径 | 50 | 56 | 62 | 63 | **64** | **65** | 66 | 70 | 72 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 球の中の輝度 | 228 | 229 | 230 | 229 | **229** | **134** | 133 | 133 | 132 |

- **64pt と 65pt の間で不連続に切り替わる**（連続補間ではない）
- 境界が直径・高さ・面積・外接矩形のどれで決まるかは不明
- 同じ 65 の境界は iOS 側でも第三者に観測されている（非公式・補助情報）
  https://github.com/callstack/liquid-glass
- 「64pt以下は適応していない」と誤読しやすいが**逆**。64pt以下こそが仕様どおり「背景に応じて反転」していて、
  65pt以上が「大きいので反転しない＝外観設定に追従」している

### 切り分けの記録（ClaudeBar・2026-08-27〜28）

3球（72 / 62 / 50pt）を同じ白背景に置くと、**72ptだけ暗く、62/50ptは真っ白**になった。原因の切り分け:

| 変えたもの | 結果 |
| --- | --- |
| 重なり順を逆にする | 変わらず → z順は無関係 |
| セッション球のロゴを消す | 変わらず → 中身は無関係 |
| 3球とも直径72pt | **3球とも暗くなる** |
| 3球とも直径50pt | **3球とも真っ白になる** |

→ **図形の大きさだけ**が効いていた。

---

## 3. 文字の自動反転（実装条件は実測）

HIG が言う「symbols and text on these elements follow a monochromatic color scheme」は、
**自作のビューでも効く**。ただし条件がある（2026-08-28実測）:

| 構成 | 白背景での文字 |
| --- | --- |
| ガラスを `.background` に敷く ＋ 文字 `.primary` | **反転しない**（白のまま） |
| **ガラスを content に掛ける（`content.glassEffect(...)`）＋ 文字 `.primary`** | **自動で黒になる** |
| 同上・暗い背景 | 白に戻る |

つまり「文字をガラスの content の中に入れる」ことが条件。`.background` に敷くとシステムから見て
「ガラスの上に載っている文字」にならない。**この条件は公式には書かれていない。**

**背景の明るさを自前で測る必要は無い**（そもそも透明ウィンドウの背後を読むには
`CGWindowListCreateImage` / ScreenCaptureKit ＝画面収録権限が必要で、常駐アプリには不適）。

---

## 4. `GlassEffectContainer`

### 公式に書かれていること

- 定義: 「複数の Liquid Glass シェイプを1つのシェイプに結合し、互いにモーフィングできるようにするビュー」
  https://developer.apple.com/documentation/swiftui/glasseffectcontainer
- 目的は3つ:
  1. **性能**: 「SwiftUI renders the effects together, improving rendering performance」
  2. **サンプリングの共有**: 「**glass can not sample other glass**, so having nearby glass elements in different containers will result in inconsistent behavior. Using a glass container allows these elements to **share their sampling region**」（WWDC323）
  3. **適応の統一**: 「**the adaptive appearance of the glass is shared across the grouped elements, which ensures that they maintain a uniform appearance as the underlying content changes**」（WWDC310）／UIKit版はより端的に「**It enforces a uniform adaptation!**」（WWDC284）
- `spacing`: 「As shapes near one another, their paths start to blend into one another」。AppKit の
  `NSGlassEffectContainerView.spacing` は既定0で、「0でもバッチ処理には十分、かつ意図しない融合を避けられる」
- `glassEffectID(_:in:)` はモーフィング用の同一性、`glassEffectUnion(id:namespace:)` は静止状態での統合
- コンテナ外に多数置くことへの警告: 「Creating too many Liquid Glass effect containers **and applying too many effects to views outside of containers** can degrade performance」

### 公式に書かれていないこと／ClaudeBar での判断

- 「uniform adaptation」がサイズ違いを混ぜたときどちらに揃うかは不明
- **コンテナは1つのSwiftUIツリー内でしか効かない。** ClaudeBar は「球ごとに独立したホスティングビュー」に
  分ける必要があった（後述）ため、**コンテナは使えない**。3球とも背後を採取できることは実測で確認済み

---

## 5. 描画の持ち上げ（ClaudeBar 最大のハマりどころ・完全に実測）

**`glassEffect` の描画は「最も外側の NSHostingView」を基準にウィンドウ単位のガラス群へ持ち上げられ、
その内側のレイヤーアニメーションを無視する。**

- 症状: 3球を1枚のSwiftUIツリーに入れると、球ごとの漂い（入れ子の `NSHostingView` のレイヤーに張った
  CAAnimation）が**画面にまったく出ない**。CAAnimation は張られており presentation レイヤーも動いているのに、
  描画だけが動かない
- `position` でも `transform.translation` でも不可
- 旧OS経路（`ultraThinMaterial`）では効く → ガラス固有の挙動
- アセンブリ（ホスティングルートの**外側**の NSView）のレイヤーアニメーションは効く
- **回避策**: 球ごとに独立した `NSHostingView` を AppKit 側の兄弟として並べる。持ち上げ先が分かれるので
  それぞれ独立に動き、かつ3球とも背後を採取する（単体実験 `scratchpad/glasstest.swift` と実機で確認）
- 外側のツリーに置いた `GlassEffectContainer` が入れ子のホスティングビュー内のガラスに効いていたのも同じ理屈

**公式にはこの話は一切書かれていない。**

---

## 6. 背後をどこまでサンプリングするか

### 公式に書かれていること

- 「**The Liquid Glass material reflects and refracts light, picking color from nearby content. To create this
  effect, the glass material samples content from an area larger than itself.**」（WWDC310 / WWDC323）
- 「**glass can't directly sample other glass**」
- `NSGlassEffectView` の公開プロパティは `contentView` / `cornerRadius` / `style` / `tintColor` のみ
  （`effectIsInteractive` は macOS 27 で追加）。**`NSVisualEffectView.blendingMode`（`.behindWindow`＝
  ウィンドウ背後とブレンド）に相当するAPIが存在しない**
  https://developer.apple.com/documentation/appkit/nsglasseffectview
- 「Setting a `contentView` allows AppKit to apply all of the necessary visual treatments… **So avoid placing
  the NSGlassEffectView behind your content as a sibling view.**」

### 公式に書かれていないこと

- **「自ウィンドウ内のみか、ウィンドウ背後（デスクトップ）まで届くか」を明言した記述は見つからなかった。**
  `blendingMode` 相当APIの不在は「ウィンドウ内のみ」の状態証拠だが、明文ではない
- 「an area larger than itself」の具体的な倍率・半径

### ClaudeBar の実測

- **屈折（レンズ）は自ウィンドウ内のコンテンツにしか掛からない。** 透明ボーダレスパネル越しのデスクトップは
  「ぼかし＋色採取」のみで曲がらない（240pt円で実測）。SwiftUI `.glassEffect` も `NSGlassEffectView` も同じ
- 一方で**明暗の適応と色の採取はデスクトップに対して効く**（白いページの上で球が明るくなる＝実測）

---

## 7. 透明・ボーダレスウィンドウ、メニューバーアプリでの使用

### 公式に書かれていること

- **直接のガイダンスは無い。** 関連する記述:
  - HIG「メニューバーエクストラ」に Liquid Glass への言及は**一切ない**
  - HIG Materials: 「**Don't use Liquid Glass in the content layer**」「controls sit on top of a system
    material, not directly on content」→ 装飾目的の「シャボン玉」は HIG 的には非推奨側に入る
  - 「Liquid Glass is designed to be an **interactive layer**… **limit Liquid Glass to the most important
    elements of your app**」（WWDC284）
  - フローティングパネルに近い唯一の公式例示は **Maps の地図上に浮かぶカスタムボタン**
  - 非アクティブウィンドウ: 「when a window loses focus… visually recedes」／HIG Windows「inactive windows
    don't use materials」
  - 「Reduce your use of **custom backgrounds**… might overlay or interfere with Liquid Glass」

### 公式に書かれていないこと

- **透明／ボーダレス `NSWindow` 上での動作保証・制限は一切文書化されていない**
- ウィンドウ背景が完全透明のとき、何を背景として適応判定するか

---

## 8. 色味を足す公式手段と、禁止されている手法

### 推奨されている手段

| 手段 | 公式記述 |
| --- | --- |
| `Glass.tint(_:)` | 「Selecting a color generates **a range of tones that are mapped to content brightness underneath** the tinted element」「tinting is natively compatible with all the behaviors of glass」 |
| `.interactive()` | タッチ／ポインタ操作に反応するコピーを返す |
| `glassEffectTransition(_:)` | `.matchedGeometry` / `.materialize` / `.identity`。「The system applies **more than opacity changes**」 |
| `.clear` + 自前 dimming | 「add a transparent black color beneath your glass」／明るいコンテンツ上では 35% opacity |
| light/dark 両方の色を定義 | 「Even if your app ships in a single appearance mode, **provide both light and dark colors to support Liquid Glass adaptivity**」 |
| `.buttonStyle(.glass)` / `.glassProminent` | 自作より標準スタイルを使う |

### 「避けよ」と明記されている手法

- **`opacity` / `alpha` を掛ける**: 「**Always prefer setting the effect property over the alpha**」（WWDC284 23:29）
- **グラスの上にグラス**: 「**always avoid glass on glass**… Instead, use fills, transparency, and vibrancy for the top elements」（WWDC219）
- **Regular と Clear の混在**: 「**They should never be mixed**」（同上）
- **不透明な solid fill での着色**: 「**breaks the visual character of Liquid Glass**」（同上）
- **全要素への tint**: 「Avoid tinting all your elements」（HIG Color）
- **`glassEffect` を見た目系modifierより前に置く**: 「Apply the `glassEffect(_:in:)` modifier **after** other modifiers that affect the appearance of the view」

---

## 9. リリースノート

macOS 26.0〜26.6 / Xcode 26 / iOS 26 のリリースノートを走査した結果、
**サイズ依存の描画差やダークモードの適応に関する記載は無い**（"glass" の出現自体がほぼゼロ）。
`AppKit Release Notes for macOS 26` という独立ページも存在しない。

---

## 10. ClaudeBar での最終判断（2026-08-28）

| 決めたこと | 値 | 理由 |
| --- | --- | --- |
| 直径 | 1つ表示 **64pt** / 3つ表示 **64・56・48pt** | 全部「小さい要素」側に入れて自動反転に乗せ、3球の見え方を揃える |
| 使用量による膨張 | **廃止** | 膨らむと使用率10%で64ptの境界をまたぎ、材質が突然切り替わる |
| ガラスの掛け方 | **content 側** | 文字の自動反転に乗せるため |
| 文字色 | `.primary` / `.primary.opacity(0.75)` | システムの monochromatic 反転に任せる |
| 変種 | `.regular`（`.clear` は不採用） | `.clear` は適応能力が無く、自動反転を失う |
| 局所クリア化 | **オフ** | 削った場所はガラスの効果ごと消える |
| `GlassEffectContainer` | **不使用** | 球ごとに別ホスティングビューへ分ける構成と両立しない（§5） |

透明度について: `.regular` を使う範囲では**この構成が最も素通し**（Apple: 小さいほど clearer）。
実測で白背景での球の中の輝度は 72pt=162 に対し 64pt以下=245（背景255）。

---

## 出典

**Apple 公式ドキュメント**
- [Glass](https://developer.apple.com/documentation/swiftui/glass) / [.regular](https://developer.apple.com/documentation/swiftui/glass/regular) / [.clear](https://developer.apple.com/documentation/swiftui/glass/clear) / [.identity](https://developer.apple.com/documentation/swiftui/glass/identity) / [tint(_:)](https://developer.apple.com/documentation/swiftui/glass/tint(_:)) / [interactive(_:)](https://developer.apple.com/documentation/swiftui/glass/interactive(_:))
- [glassEffect(_:in:)](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) / [GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer) / [glassEffectID](https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:)) / [glassEffectUnion](https://developer.apple.com/documentation/swiftui/view/glasseffectunion(id:namespace:)) / [glassEffectTransition](https://developer.apple.com/documentation/swiftui/view/glasseffecttransition(_:))
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview) / [NSGlassEffectContainerView](https://developer.apple.com/documentation/appkit/nsglasseffectcontainerview)
- [Liquid Glass 技術概要](https://developer.apple.com/documentation/technologyoverviews/liquid-glass) / [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

**HIG**
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials) / [Color](https://developer.apple.com/design/human-interface-guidelines/color) / [The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar) / [Windows](https://developer.apple.com/design/human-interface-guidelines/windows)

**WWDC25**
- [219 Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)（サイズと適応: [6:51](https://developer.apple.com/videos/play/wwdc2025/219/?time=411) / [15:16](https://developer.apple.com/videos/play/wwdc2025/219/?time=916)）
- [284 Build a UIKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/284/)（**サイズ依存の明文: [21:30](https://developer.apple.com/videos/play/wwdc2025/284/?time=1290)**、alpha非推奨 [23:29](https://developer.apple.com/videos/play/wwdc2025/284/?time=1409)、uniform adaptation [24:51](https://developer.apple.com/videos/play/wwdc2025/284/?time=1491)）
- [310 Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/)（サンプリング領域・コンテナ [20:31](https://developer.apple.com/videos/play/wwdc2025/310/?time=1231)）
- [323 Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/) / [356 Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/)

**非公式（補助）**
- [callstack/liquid-glass](https://github.com/callstack/liquid-glass) — iOS側でも「height >= 65 で自動適応が効かない」との記載

---

## 11. パネルの背景は Liquid Glass ではなく**標準マテリアル**（2026-08-29 調査＋実測）

### 公式に書かれていること

HIG「Materials」（Change log: 2025-09-09＝Liquid Glass 対応後の改訂）は素材を2種類に分けている。

> Apple platforms feature **two types of materials: Liquid Glass, and standard materials.**

> **Don't use Liquid Glass in the content layer.** … **Instead, use Standard materials for elements in the
> content layer, such as app backgrounds.**

> **macOS** — macOS provides several standard materials with designated purposes… For developer guidance,
> see `NSVisualEffectView.Material`.

> **Use Liquid Glass effects sparingly.** … Limit these effects to the most important functional elements in your app.

つまり **300×460pt のパネル全面を `.glassEffect` で塗るのは想定外**で、背景は標準マテリアル、
Liquid Glass はバブルやボタンのような浮いている要素だけ、が公式の構成。

**`NSVisualEffectView` は廃止されていない**（macOS 26.5 SDK のヘッダで確認: `.menu`(5) / `.popover`(6) /
`.sidebar`(7) / `.hudWindow`(13) はいずれも非 deprecated。deprecated なのは 10.14 で切られた
`.light` / `.dark` / `.mediumLight` / `.ultraDark` / `.appearanceBased` のみ）。
WWDC25 310 の「visual effect view を外せ」という指示は**サイドバー限定**の話。

その他:
- **`tint` は「強調」用**: 「Assign a tint color to suggest prominence」「Apply color sparingly …
  reserve it for elements that truly benefit from emphasis」「Tinting should only be used to bring emphasis」。
  **減光目的で無彩色を薄く乗せるのは想定用途外**。しかも tint は「背後の明度にマッピングされたトーンの
  レンジを生成する」ので、**壁紙が変われば効き方も変わる**
- **透過度を直接下げる公式のノブは存在しない**（SDK 実確認: `Glass` は regular / clear / identity /
  tint / interactive の5つだけ、`NSGlassEffectView` は contentView / cornerRadius / tintColor / style の4つだけ）。
  Apple が数値を出している減光手法は「`.clear` + 35% の暗いディミングレイヤー」のみ
- **Control Center のモジュールと同じ見た目を作る公式APIは無い**（サードパーティが出せるのは
  ボタン/トグルの `ControlWidget` だけ）。HIG に「Control Center」のページ自体が存在しない
- HIG「The menu bar」はメニューバーエクストラに**まずメニュー**を勧め、ポップオーバーは
  「メニューでは複雑すぎる場合」の例外。公式の代替は SwiftUI `MenuBarExtra` +
  `.menuBarExtraStyle(.window)`（「more complex or data rich menu bar extras」向けと明記）か `NSPopover`
- macOS 27 では `NSStatusItem.expandedInterfaceSession` が追加され、**自作ウィンドウを status item から
  出す構成が公式にサポートされる**（macOS 26 SDK には未収録）

### 公式に書かれていないこと

- **macOS 26 上で `.popover` / `.menu` マテリアルが「新デザインの背景」を描くのか、旧世代のブラーのままか**
- 自作ウィンドウを NSMenu / NSPopover と同じ背景に揃える手段
- tint に無彩色を使うことの可否（明示的な言及なし）

### 実測して選んだ素材（ダーク外観・パネル内の輝度 0-255）

| 素材 | 白背景 | 黒背景 | 背景の通し量 |
| --- | --- | --- | --- |
| 旧: Liquid Glass `.regular` + `windowBackgroundColor` 20% | 106 | 41 | 26% |
| **`.menu`（採用）** | **105** | **37** | **26%** |
| `.popover` | 125 | 33 | 36%（透けすぎ） |
| `.hudWindow` | 166 | 26 | 55%（透けすぎ） |

- `.menu` は**調整済みのガラスと同じ濃さ**になり、かつ「メニューバー由来のパネル」という
  意味論にも合う（HIG:「Choose materials based on semantic meaning」）
- `.popover` は名前に反して**より透ける**。今回の「システムのパネルより明るく見える」問題は解決しない
- ウィンドウ/パネルの外観（`effectiveAppearance`）は全素材で `NSAppearanceNameDarkAqua` のまま。
  素材によって明暗が変わるのは**マテリアルの性質**であって外観の反転ではない（実測で確認）

### 実装（`PanelViews.swift`）

- `PanelBackdrop`（`NSViewRepresentable`）: `NSVisualEffectView` を `blendingMode = .behindWindow`、
  `state = .active`、`material = .menu` で敷く。角丸は `maskImage`（capInsets 付きの伸縮画像）で付ける
- **旧OS分岐が不要になった**（`NSVisualEffectView` は macOS 14 から同じ API）。パネルは全OS共通経路
- 検証用: `CLAUDEBAR_PANEL_MATERIAL=menu|popover|hud|sidebar|glass`（`glass` で従来の Liquid Glass 経路に戻せる）
