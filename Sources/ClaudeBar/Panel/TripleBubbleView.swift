import SwiftUI

/// トリプルバブル（設計は TRIPLE_BUBBLE.md。2026-08-21に融合廃止で再設計）。
///
/// 3つの使用量（セッション / Fable週間 / 週間すべて）を重要度順の大きさで浮かべる。
/// かつての表面張力（融合＝メタボールのくびれ）は廃止した: 融合があると球の位置を
/// SwiftUI値で動かすしかなく、球ごとの漂いはどの実装でも7-13%CPUを食い続けたため（実測）。
/// 現在は球ごとに DriftHost（レンダーサーバ常駐のCAAnimation）で独立に漂わせ、約1%CPUで済む。
/// ※ GlassEffectContainer 自体は今も使う（融合はさせない）— 理由は unifiedBody を参照。
///
/// 描画は「単体バブル（BubbleView）を3つ、違う大きさで並べたもの」であること。
/// レイヤー構成・ガラス・装飾は BubbleSphere / BubbleDecoration.swift で単体と共有し、
/// 3つ表示だけの独自レイヤーは持たない（詳細は docs/BUBBLE_RENDERING.md）。
struct TripleBubbleView: View {
    var state: AppState
    var settings: SettingsStore
    var cluster: TripleBubbleCluster
    var actions: PanelActions

    /// ウィンドウサイズ（塊 + 漂い・膨張の余白）
    static let windowSize = CGSize(width: 220, height: 210)

    var body: some View {
        unifiedBody
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        // 再表示のたびにビューを作り直して漂いを始め直す（隠している間に
        // レンダーサーバから破棄された宣言的アニメーションは自動では戻らない）
        .id(cluster.showGeneration)
        .contextMenu {
            Button(L("bubble.expandToPanel")) { actions.expand() }
            Button(L("bubble.closeBubble")) { actions.toBubble() }
            Divider()
            Button(L("bubble.settingsMenu")) { actions.settings() }
            Button(L("bubble.quit")) { actions.quit() }
        }
        .help(L("bubble.helpTriple"))
    }

    /// 全OS共通の本体（球ごとのDriftHost漂い+静的配置）。
    ///
    /// GlassEffectContainer で括るのが必須（2026-08-27実測）: 透明ウィンドウ内で
    /// 素の `.glassEffect` を複数置くと、背後を採取するのは最前面の1つだけで、
    /// 残りはただの素通しになる（3つ表示で2番目・3番目の球だけガラスが消えた）。
    /// spacing: 0 なので融合（メタボールのくびれ）は起きず、球はそれぞれ独立に見える。
    /// かつて融合を使っていた頃のCPU問題は「球の位置をSwiftUI値で動かす」ことが原因で、
    /// コンテナ自体ではない — 位置は今も DriftHost（CAAnimation）が動かす
    @ViewBuilder
    private var unifiedBody: some View {
        if #available(macOS 26.0, *), !forceLegacyUI {
            GlassEffectContainer(spacing: 0) { balls }
        } else {
            balls
        }
    }

    private var balls: some View {
        // 漂いは球ごとの DriftHost（レンダーサーバ常駐のCAAnimation）が担当する。
        // SwiftUIの宣言的アニメーションで動かすと待機中7-13%CPUを食う（実測）
        ZStack {
            ForEach(TripleBubbleCluster.Slot.allCases, id: \.self) { slot in
                if !cluster.poppedSlots.contains(slot.index) {
                    let p = cluster.driftParams(for: slot)
                    DriftHost(
                        amplitudeX: p.ax, durationX: p.dx,
                        amplitudeY: p.ay, durationY: p.dy,
                        phase: p.phase
                    ) {
                        ball(slot)
                            .frame(width: Self.windowSize.width, height: Self.windowSize.height)
                    }
                    // 優先度どおりの重なり: セッションが常に手前、週間が最背面
                    .zIndex(Double(TripleBubbleCluster.Slot.allCases.count - slot.index))
                }
            }
        }
    }

    /// 球1つ。単体バブルと同じ「装飾ZStack + ガラス玉」の組で、3つ表示だけの
    /// 縁レイヤー（旧 BubbleIridescentEdge / GlassTubeRim）は持たない
    /// — それらは単体バブル側で BubbleGlossOverlay のフレネル+薄膜干渉に統合済み
    @ViewBuilder
    private func ball(_ slot: TripleBubbleCluster.Slot) -> some View {
        let diameter = cluster.diameter(for: slot, state: state)
        BubbleFace(
            slot: slot,
            diameter: diameter,
            state: state,
            settings: settings,
            isPrimary: slot == .session
        )
        .scaleEffect(cluster.bounceScales[slot.index])
        // 割れた球は上の if で丸ごと外れるので、ここに opacity/scale の
        // 破裂演出は置かない（ガラスへの .opacity() は屈折を殺すので厳禁）
        .position(cluster.home(for: slot))
        .offset(cluster.dragOffsets[slot.index])
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: cluster.dragOffsets[slot.index])
    }
}

/// 3つ表示のガラス玉。単体バブルの SingleBubbleGlass と同じ `.regular` を使うが、
/// 背景の円ではなく content 自身へ適用する — GlassEffectContainer 配下では
/// `.background` に置いたガラスが中身より前面へ持ち上がって内容を隠すため。
struct TripleBubbleGlass: ViewModifier {
    /// 使用量リングの進捗（0-1）。マスクが弧の真下だけ磨りを復元するのに使う
    var ringFraction: Double = 0

    func body(content: Content) -> some View {
        // コンテナ配下ではガラスを content 形式で掛けるしかないため、マスクは
        // リング・文字・装飾ごと掛かる。BubbleClarityMask は文字コラムとリング帯を
        // 保護する設計なので、実際に薄まるのはクリアパッチの場所だけ
        // （パッチ位置の薄膜が少し暗くなるのは実物の膜ムラと同じで許容）。
        // なおリングを兄弟レイヤーへ出す案は不可 — コンテナがガラスを兄弟より
        // 前面へ集約するため、リングが磨りガラス越しのボケた塊になる（2026-08-27実測）
        if #available(macOS 26.0, *), !forceLegacyUI {
            content.glassEffect(.regular, in: Circle())
                .mask(BubbleClarityMask(ringFraction: ringFraction))
        } else {
            content.background(
                Circle().fill(.ultraThinMaterial).opacity(0.72)
                    .mask(BubbleClarityMask(ringFraction: ringFraction))
            )
        }
    }
}

/// 球1つぶんの見た目。単体バブル（BubbleView）と同じレイヤー構成を
/// 基準径72pt=1のスケール s で一律に拡縮する（＝単体を別の大きさで描いたもの）。
/// 装飾の .screen / .plusLighter はガラスが同じ合成文脈の背後にいるときだけ
/// 加算で効くので、drawingGroup で焼いてはいけない（光ではなく白い膜になる）
struct BubbleFace: View {
    var slot: TripleBubbleCluster.Slot
    var diameter: CGFloat
    var state: AppState
    var settings: SettingsStore
    var isPrimary: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var window: UsageWindow? { state.usage?.window(for: slot.metric) }
    private var value: Double { window?.utilization ?? 0 }

    /// 基準径72ptを1としたスケール（リングの太さ・位置も単体バブルと同じ比率に保つ）
    private var s: CGFloat { diameter / 72 }

    private var tint: Color {
        if value >= 95 { return .red }
        if value >= 80 { return .orange }
        return settings.useSystemAccent ? Color(nsColor: .controlAccentColor) : .claudeOrange
    }

    private var percentText: String {
        state.usage == nil ? "–%" : "\(Int(value.rounded()))%"
    }

    var body: some View {
        // 単体バブル（BubbleView）と同じ層構成:
        //   ガラス(クリア化マスク付き) → 拡散照明 → 文字 → 光沢/虹 → リング
        // ただし GlassEffectContainer 配下では文字をガラスと同じ部分木に置く必要が
        // ある（コンテナはガラスを非ガラスの兄弟より前面へ集約するため）ので、
        // 「照明+文字」にガラスを掛け、光沢とリングは兄弟レイヤーとして上に重ねる
        ZStack {
            ZStack {
                BubbleDepthUnderlay(s: s)
                WobbleHost(
                    // 球ごとに振れ幅・周期・開始位相の全てをずらして
                    // 「それぞれが独立に生きている」ゆらぎにする
                    amplitudeDegrees: [3.0, 2.4, 3.6][slot.index],
                    period: 2 * .pi / 0.9 * [1.0, 1.17, 0.86][slot.index],
                    phase: [0, 0.37, 0.71][slot.index]
                ) {
                    VStack(spacing: 0) {
                        if isPrimary {
                            // 主役のセッションだけロゴを出す（小さい球は%だけで詰まらせない）。
                            // サイズは単体バブルと同じ16pt
                            ClaudeLogoView(
                                animating: state.isActive,
                                color: state.isActive ? .claudeOrange : BubbleStyle.resolve(colorScheme).logoIdleColor
                            )
                            .frame(width: 16, height: 16)
                        }
                        Text(percentText)
                            // 文字だけは球の大きさに比例させない（50pt球で9ptまで落ちて読めなくなる）。
                            // 単体バブルが膨らんでも文字サイズを固定するのと同じ考え方
                            .font(.system(size: isPrimary ? 13 : 11))
                            .monospacedDigit()
                            .foregroundStyle(BubbleStyle.resolve(colorScheme).textColor)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.4), value: percentText)
                            .modifier(BubbleTextHalo(colorScheme: colorScheme))
                        Text(slot.caption(fableLabel: state.fableLabel))
                            .font(.system(size: isPrimary ? 9 : 8))
                            .foregroundStyle(BubbleStyle.resolve(colorScheme).textColor.opacity(BubbleStyle.resolve(colorScheme).secondaryTextOpacity))
                            .modifier(BubbleTextHalo(colorScheme: colorScheme))
                    }
                }
                // 光沢・虹は必ずガラスと同じ部分木に置く（.screen加算はガラスが
                // 同じ合成文脈の背後にいる時だけ光として効く。兄弟に出すと
                // コンテナがガラスを引き剥がし、透明背景に対してフル彩度で乗る）
                BubbleGlossOverlay(s: s)

                // 使用量リング。単体バブル（72ptで線幅4・余白4）と同じ比率。
                // 虹より前面に置き、ゲージの色が虹に染まらないようにする。
                // 兄弟レイヤーには出せない（上記コンテナ制約でボケるため部分木内の最前面）
                Circle()
                    .trim(from: 0, to: max(0.003, min(value, 100) / 100))
                    .stroke(
                        LinearGradient(colors: [tint, tint.ringDeepened],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 4 * s, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(4 * s)
            }
            .padding(3 * s)
            .frame(width: diameter, height: diameter)
            .modifier(TripleBubbleGlass(ringFraction: min(value, 100) / 100))
        }
    }
}
