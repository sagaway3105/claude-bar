# macOS 26 のウィンドウまわりの仕様メモ（2026-08-29 調査）

扱う話題: **角丸**（§0-9）と、**開閉アニメーションの速度**（§10）。

「設定ウィンドウの角丸がシステム設定と違う」の原因調査。結論は
**ツールバーの有無で角丸が2クラスに分かれる**という macOS 26 の仕様で、公式にも明記がある。

---

## 0. 30秒サマリ

| 論点 | 結論 | 根拠 |
| --- | --- | --- |
| なぜ違うのか | **ツールバーの有無**。持つと大きい角丸、タイトルバーのみだと小さい角丸 | **公式**（WWDC25 310） |
| ウィンドウの大きさは関係するか | **しない**（実測でも公式の文面でも） | 実測＋公式 |
| 具体的な数値 | **公式にはどこにも無い**。実測で 17.5pt / 31.5pt | 実測のみ |
| 角丸を指定するAPI | **`NSWindow` に存在しない** | 公式（全シンボル確認） |
| `layer.cornerRadius` での模倣 | **HIG が明確に禁止** | 公式 |
| 設定ウィンドウにツールバーを付けるべきか | **HIG がそう書いている**（角丸目当てのハックではない） | 公式（HIG Settings） |
| この仕様の寿命 | **macOS 27 で撤廃**。全ウィンドウが統一の（より小さい）半径へ | 公式（WWDC26 SOTU） |

---

## 1. 実測（macOS 26.5 SDK / AppKit）

`NSWindow` を素朴に作り、ウィンドウキャプチャのアルファから角の半径を測った
（検証コード: `scratchpad/wintest.swift`）。

| 構成 | 角の半径 |
| --- | --- |
| `styleMask: [.titled, .closable]`（＝ClaudeBar の設定ウィンドウ） | **17.5pt** |
| `[.titled, .closable, .resizable]` | 17.5pt |
| `[.titled, .closable, .resizable]` + **`window.toolbar = NSToolbar(...)`（空でも）** | **31.5pt** |
| `+ .fullSizeContentView` | 17.5pt |
| ツールバー無しで、ツールバー版と同じ高さにしたもの | 17.5pt |

→ **ツールバーの有無だけが効く。高さ・リサイズ可否・fullSizeContentView は無関係。**

ClaudeBar のパネル（メニューバーから開くほう）は**ボーダレスウィンドウに自前で描いている**ため
この規則の対象外で、`RoundedRectangle(cornerRadius: 18)` の値がそのまま出る（実測 17.5pt）。

---

## 2. 公式記述

### 決定的な一節（WWDC25 セッション310「Build an AppKit app with the new design」）

> In the new design system, windows now have a softer, more generous corner radius, **which varies based on the style of window.**

> **Windows with toolbars now use a larger radius**, which is designed to wrap concentrically around the glass toolbar elements, **scaling to match the size of the toolbar**. **Titlebar-only windows retain a smaller corner radius**, wrapping compactly around the window controls.

https://developer.apple.com/videos/play/wwdc2025/310/

- 大きい方の理由 = **ガラスのツールバー要素を同心円状に包むため**
- 小さい方の理由 = **ウィンドウコントロール（信号機ボタン）にコンパクトに寄り添うため**
- 「varies based on the **style** of window」とだけ言っており、**サイズには触れていない**（実測と一致）

同セッションは副作用にも触れている:

> These larger corners provide a softer feel and elegant concentricity to the window **but they can also clip content that sits close to the edge of the window.** To position content that nests into a corner, use the new `NSView.LayoutRegion` API.

### 周辺の記述

- Adopting Liquid Glass（定性のみ）: 「Windows adopt rounder corners to fit controls and navigation elements.」
  https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- WWDC25 356: 「concentric shapes calculate their radius by subtracting padding from the parent's」
- **HIG の Windows / Layout ページには角丸の記述が一切無い**（Windows の change log は 2025-06-09 が最終で、
  Liquid Glass 対応の更新すらされていない）

---

## 3. 数値は非公開

以下すべてを当たって、**ウィンドウ角丸の数値は一切出てこない**（"larger" / "smaller" / "softer" /
"more generous" という定性表現のみ）:

- WWDC25 セッション 310 / 356 / 323 / 219 の全トランスクリプト
- HIG Windows / Toolbars / Layout / Settings
- Adopting Liquid Glass、Liquid Glass technology overview
- macOS 26.0〜26.6 リリースノート
- AppKit / SwiftUI の API リファレンス

Apple は数値をハードコードさせない方針を明言している:

> If you use standard controls from system frameworks and **don't hard-code their layout metrics**, your app adopts changes to shapes and sizes automatically when you rebuild your app with the latest version of Xcode.

第三者（Lapcat Software / Jeff Johnson）も同じ現象を独立に観測しているが数値は出していない。
つまり **17.5pt / 31.5pt は現時点で我々の実測が最も具体的な情報**。
https://lapcatsoftware.com/articles/2026/3/1.html

---

## 4. API

### `NSWindow` に角丸のプロパティは無い

AppKit の全シンボルを走査しても、`corner` を含むのは `NSView` / `NSBox` / `NSGlassEffectView` /
`NSApplication` 系のみ。`NSWindow` は0件。AppKit の更新履歴にも追加は無い。

### あるのは「ビューが容器（ウィンドウ）の角に合わせる」ための API（macOS 26 新規）

| API | 用途 |
| --- | --- |
| `NSView.cornerConfiguration: NSViewCornerConfiguration?` | ビューの角の形を定義 |
| `NSViewCornerRadius.containerConcentric` | 「container の形状から動的に算出される半径」 |
| `NSViewCornerRadius.containerConcentric(_:)` | 同上＋最小半径フォールバック |
| `NSViewCornerRadius.fixed(_:)` | 固定pt |
| `NSView.effectiveCornerRadii` | 解決後の実効半径を**読む** |
| `NSView.viewDidChangeEffectiveCornerRadii()` | 変化通知 |
| `NSView.LayoutRegion.safeArea(cornerAdaptation:)` / `.margins(cornerAdaptation:)` | 角を避けるレイアウトガイド |
| `NSGlassEffectView.cornerRadius` | グラスビューの角丸（ウィンドウではない） |

SwiftUI 側は `.background(.tint, in: .rect(corner: .containerConcentric))`。
macOS 27 では `GeometryProxy.concentricCornerRadii` で読み取りもできる。

### 旧デザインに戻す公式スイッチ

`UIDesignRequiresCompatibility`（Info.plist, Boolean）。ただし**角丸だけでなくUI全体**が戻り、
**macOS 27 以降は無視される**ので恒久的解決にはならない。
https://developer.apple.com/documentation/bundleresources/information-property-list/uidesignrequirescompatibility

### 禁止されていること

HIG Windows:

> **Avoid creating custom window UI.** System-provided windows look and behave in a way that people understand and recognize. **Avoid making custom window frames or controls, and don't try to replicate the system-provided appearance.** Doing so without perfectly matching the system's look and behavior can make your app feel broken.

`contentView.layer.cornerRadius` でウィンドウ角丸を模倣しても、ウィンドウの実形状・シャドウ・
リサイズ当たり判定はシステムのフレームビューが持つため一致しない（これは実測知見であって公式記述ではない）。

---

## 5. HIG が求める「設定ウィンドウ」の構成

HIG Settings（macOS）は、**設定ウィンドウはツールバーを持つのが典型**と明記している。
つまりツールバーを付けるのは角丸目当てのハックではなく、本来求められている構成。

> Typically, a custom settings window contains a toolbar that includes buttons for switching between views — called panes — that each contain a group of related settings.

> **In your settings window, use a noncustomizable toolbar that remains visible and always indicates the active toolbar button.**

> **Dim a settings window's minimize and maximize buttons.**

> **Update the window's title to reflect the currently visible pane.** If your settings window doesn't have multiple panes, use the title *App Name* Settings.

> **Restore the most recently viewed pane.**

> **Include a settings item in the App menu.** Avoid adding settings buttons to a window's toolbar.

https://developer.apple.com/design/human-interface-guidelines/settings

AppKit 側の対応は `NSWindow.toolbarStyle = .preference`
（「A style indicating that the toolbar appears below the window title with toolbar items centered」）。

**書かれていないこと**: 「ツールバーを付けると System Settings と同じ角丸になる」という因果は
HIG Settings には書かれていない。セッション310 と HIG Settings を突き合わせて初めて導ける。

---

## 6. SwiftUI の場合

- `Settings` シーンの推奨構成は `Settings { TabView { Tab(...) } }`
  https://developer.apple.com/documentation/swiftui/settings
- `.windowToolbarStyle(_:)` は `.automatic` / `.expanded` / `.unified` / `.unifiedCompact` のみで、
  **AppKit の `.preference` に相当するものは SwiftUI に無い**
- **SwiftUI で作ったウィンドウの角丸がどうなるかは一切文書化されていない。**
  論理的にはセッション310の規則が下層の `NSWindow` に適用されるはずだが、これは推論

---

## 7. リリースノート

macOS 26.0〜26.6 を走査した結果、角丸そのものの変更記述はゼロ。関連するのは1件のみ:

- macOS 26.3 Known Issues: 「Window resize pointer does not follow the window's corner shape. (149726089)」
- macOS 26.4 Resolved Issues: 同件が修正

---

## 8. ★ macOS 27 でこの仕様は撤廃される

WWDC26 Platforms State of the Union（2026年6月）:

> And **every window on macOS now also has the same tighter corner radius, ensuring greater consistency across all apps.**

https://developer.apple.com/videos/play/wwdc2026/102/

**macOS 26 の2クラス制は過渡的な仕様。** 数値を焼き込むと macOS 27 で破綻する。

---

## 8.5. `toolbarStyle` でも角丸が変わる（2026-08-29 実測・公式は定性のみ）

セッション310 は「scaling to match the size of the toolbar」と言っているだけで数値は無いが、
実際に `toolbarStyle` を振ると3段階に分かれた（`scratchpad/tbtest.swift`）。

| `toolbarStyle` | 角丸 | 見た目 |
| --- | --- | --- |
| `.automatic` | **31.5pt** | タイトル行にツールバーが載る |
| `.unified` | **31.5pt** | 同上 |
| `.unifiedCompact` | 23.0pt | 同上・低い |
| `.expanded` | 17.5pt | タイトルの下にツールバー |
| **`.preference`** | **17.5pt** | 同上（旧来の環境設定スタイル） |

**注意**: HIG Settings が設定ウィンドウに挙げている `.preference` は、**小さい角丸側**。
System Settings と同じ大きい角丸にしたいなら `.automatic` / `.unified` を選ぶ必要がある。
（System Settings 自身はサイドバー＋unified 構成）

## 9. ClaudeBar への適用

### 現状（2026-08-29 に選択肢1で実装済み）

| ウィンドウ | 構成 | 角丸 |
| --- | --- | --- |
| 設定ウィンドウ | ツールバー（4ペイン）＋ `toolbarStyle = .preference`、幅380pt | 17.5pt |
| パネル | ボーダレス `NSPanel` ＋ 自前 `RoundedRectangle(cornerRadius: 18)` | 17.5pt（自前の値） |
| バブル | ボーダレス `NSPanel` ＋ `Circle()` | — |

### 実装した内容（選択肢1）

- `一般 / バブル / 通知 / システム` の**4ペインに分割**し、それぞれをツールバー項目にした
- `NSToolbar`（`allowsUserCustomization = false`・`displayMode = .iconAndLabel`）＋
  **`toolbarStyle = .preference`**（タイトルの下にアイコンを中央並べ＝設定ウィンドウの定番配置）
- **角丸と配置はトレードオフになった**: `.automatic` にすれば System Settings と同じ 31.5pt になるが、
  ペイン切り替えをタイトル行に右寄せで置く形になり、設定ウィンドウの慣習から外れる。
  **配置を優先**して `.preference`（角丸は17.5pt）を選んだ。角丸は macOS 27 で全ウィンドウ統一に
  戻る予告があるため、いま合わせても来年ズレる
- バブルのペインだけ、アイコンはアプリ自前のシャボン玉（`BubbleSparkleIcon(showsSparkle: false)` を
  `ImageRenderer` で NSImage に焼き、`isTemplate = true`）。キラキラの十字はプラス記号に見えるので落とす
- HIG の要求に合わせた: **タイトルは表示中ペイン名**／**最小化・ズームは出すが淡色化**
  （`standardWindowButton(_:)?.isEnabled = false`）／**前回のペインを復元**（UserDefaults `settingsPane`）／
  ツールバーは選択状態を常に示す（`toolbarSelectableItemIdentifiers`）
- **幅は380pt**。`.preference` は項目が独立した行に中央並びするのでタイトルと取り合いにならない
  （`.automatic` でタイトル行に載せる場合は **520pt 必要**。460ptだと2項目でオーバーフローの `»` に落ちる。
  さらに最後の項目が大きい角丸に食い込むため、末尾に固定 `.space` を2つ入れる必要があった。
  `.flexibleSpace` では動かない）
- 高さは `NSHostingView.fittingSize` でペインごとに合わせ、上端を固定して伸縮させる
  （Form(.grouped) は与えられた高さいっぱいに広がるので、`.fixedSize(horizontal: false, vertical: true)` が必要）
- リサイズは `contentMinSize == contentMaxSize` で禁止（HIG: 設定は安定した見た目を保つ）

### 残っている選択肢

- パネル（メニューバーから開くほう）の角丸は自前の値（`cornerRadius: 18` → 実測17.5pt）なので自由に変えられる。
  ただし**数値の焼き込みは macOS 27 で破綻する**ことに留意

### 追試の余地（未検証）

- ツールバーの高さ／`toolbarStyle`（`.preference` / `.unifiedCompact` / `.expanded`）で 31.5pt が変わるか
  （公式は "scaling to match the size of the toolbar" と言っている）
- SwiftUI `Settings { TabView }` と `Settings { Form }` で角丸が変わるか
- `contentView` に `cornerConfiguration` を設定したときウィンドウ形状に伝播するか

---

## 出典

- [Build an AppKit app with the new design — WWDC25 310](https://developer.apple.com/videos/play/wwdc2025/310/)
- [Get to know the new design system — WWDC25 356](https://developer.apple.com/videos/play/wwdc2025/356/)
- [Modernize your AppKit app — WWDC26 289](https://developer.apple.com/videos/play/wwdc2026/289/)
- [Platforms State of the Union — WWDC26 102](https://developer.apple.com/videos/play/wwdc2026/102/)
- [HIG: Windows](https://developer.apple.com/design/human-interface-guidelines/windows) / [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) / [Settings](https://developer.apple.com/design/human-interface-guidelines/settings) / [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [NSWindow](https://developer.apple.com/documentation/appkit/nswindow) / [NSWindow.ToolbarStyle.preference](https://developer.apple.com/documentation/appkit/nswindow/toolbarstyle-swift.enum/preference)
- [NSViewCornerConfiguration](https://developer.apple.com/documentation/appkit/nsviewcornerconfiguration) / [containerConcentric](https://developer.apple.com/documentation/appkit/nsviewcornerradius/containerconcentric) / [effectiveCornerRadii](https://developer.apple.com/documentation/appkit/nsview/effectivecornerradii) / [NSView.LayoutRegion](https://developer.apple.com/documentation/appkit/nsview/layoutregion)
- [SwiftUI Settings](https://developer.apple.com/documentation/swiftui/settings) / [WindowToolbarStyle](https://developer.apple.com/documentation/swiftui/windowtoolbarstyle) / [GeometryProxy.concentricCornerRadii](https://developer.apple.com/documentation/swiftui/geometryproxy/concentriccornerradii)
- [UIDesignRequiresCompatibility](https://developer.apple.com/documentation/bundleresources/information-property-list/uidesignrequirescompatibility)
- [macOS 26.3](https://developer.apple.com/documentation/macos-release-notes/macos-26_3-release-notes) / [26.4](https://developer.apple.com/documentation/macos-release-notes/macos-26_4-release-notes)
- 参考（非公式）: [Lapcat Software](https://lapcatsoftware.com/articles/2026/3/1.html)

---

## 10. ウィンドウ/メニュー/ポップオーバーの開閉アニメーション速度

### 結論

**メニュー・ポップオーバー・パネルの表示/非表示の duration とイージングについて、Apple の公式な数値は存在しない。**
HIG の全172ページを機械的に走査して確認した:

- HIG 全体で**秒数を含む記述は2件のみ**で、いずれも無関係（動画再生の "0.5 seconds" と "30 seconds"）
- "Reduce Motion" に言及する HIG ページは **Accessibility の1ページだけ**
- **"cross-fade" を含む HIG ページは0件**

### 唯一 Apple 自身が書いている数値: 0.25秒

**AppKit Release Notes（macOS 10.12 以前・アーカイブ）** の NSAnimationContext 節:

> Each thread starts with a current NSAnimationContext whose **default duration is 0.25 seconds**
> (the same default value used by Core Animation), meaning that value-set operations for animatable
> object properties that go through "animator" proxies will animate with that duration by default.

同じ文書に、**`NSWindow` の `alphaValue` / `frame` は `animator()` 経由で自動アニメーションする対象**として
明示的に列挙されている。

> Basic default animation parameters are provided for the following NSView and NSWindow properties …
> **for NSWindow: alphaValue, frame**

注意: これは2007年（Leopard）由来の**アーカイブ文書**で、現行の `NSAnimationContext.duration` の
リファレンスにも SDK ヘッダにも既定値の記載はない。「現行リファレンスには無いが、
Apple 自身が書いた唯一の出典としては存在する」という位置づけ。
https://developer.apple.com/library/archive/releasenotes/AppKit/RN-AppKitOlderNotes/

### そのほか公式に書かれていること

| 項目 | 内容 |
| --- | --- |
| `NSAnimationContext.timingFunction` の既定 | **`nil`**（＝公式に推奨されるイージングカーブは無い） |
| 進行中アニメーションの停止 | 「**duration 0.0 の `NSAnimationContext`** で新しい値を設定すると止まる」— ちらつき対策に直結 |
| `NSWindow.animationBehavior` | 5ケース（default / none / documentWindow / utilityWindow / alertPanel）。**各ケースが視覚的に何をするか・何秒かは非公開**。`.none` は "may be useful when you perform your own window animation" |
| `orderFront(_:)` / `orderOut(_:)` | どちらも「window type に基づく既定アニメーションが使われる（`animationBehavior` で変更しない限り）」 |
| `NSPopover.animates` | 既定 true。**duration の記載は無い** |
| Reduce Motion | macOS で取れるのは粗い `accessibilityDisplayShouldReduceMotion` だけ。iOS の `prefersCrossFadeTransitions` に**AppKit の等価物は無い** |

### ClaudeBar の現状と含意

| | 現状 | 公式との関係 |
| --- | --- | --- |
| パネルの開閉 | **フェード無しの完全同期**（過去にフェードがちらつきの原因だったため全廃） | 公式に反する記述は無い。メニューは即座に出るのが自然 |
| バブルの消去 | `NSAnimationContext` で **0.18秒** のフェードアウト | AppKit 既定（0.25秒）より速い。**duration を指定せず既定のまま `animator().alphaValue` を使う**のが、恣意的な数値を選ばずに済む唯一の裏づけある選択肢 |

フェードを足す/直す場合の公式に文書化された手当て:
- `window.animationBehavior = .none` で AppKit 側の自動アニメーションを止めてから自前でフェードする
- 進行中のアニメーションは **duration 0.0 の `NSAnimationContext`** で即座に止める
- Reduce Motion 時にフェードを消す必要は無い（**フェード自体が Reduce Motion の推奨代替**なので、残す方が指針に沿う）

