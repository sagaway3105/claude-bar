import SwiftUI

/// トリプルバブル（設計は TRIPLE_BUBBLE.md。2026-08-21に融合廃止、2026-08-27に
/// 「球ごとに独立したホスティングビュー」へ再設計）。
///
/// 3つの使用量（セッション / Fable週間 / 週間すべて）を重要度順の大きさで浮かべる。
///
/// **球は1枚のSwiftUIツリーにまとめない。** `glassEffect` の描画は最も外側の
/// NSHostingViewを基準にウィンドウ単位のガラス群へ持ち上げられ、その内側のレイヤー
/// アニメーションを完全に無視する（2026-08-27実測。詳細は docs/BUBBLE_RENDERING.md）。
/// 1枚にまとめると球ごとの漂い（DriftHost）が画面に出ない。
/// そこで **球ごとに独立した `DriftHostView`（＝独立したNSHostingView）をアセンブリ直下の
/// 兄弟として並べ**、各ホストのレイヤーにCAAnimationを張る（PanelController+Bubble の
/// `configureBubbleContent`）。持ち上げ先が球ごとに分かれるため、3球とも背後を採取しつつ
/// それぞれ独立に漂う。融合（GlassEffectContainer）はもう使わない。
///
/// 描画は「単体バブル（BubbleView）を3つ、違う大きさで並べたもの」であること。
/// レイヤー構成・ガラス・装飾は BubbleFace / BubbleDecoration.swift で単体と共有し、
/// 3つ表示だけの独自レイヤーは持たない（詳細は docs/BUBBLE_RENDERING.md）。

/// 球1つぶんのキャンバス。ウィンドウ全体と同じ大きさを持ち、その中の
/// ホーム位置に球を1つだけ置く（重なり順はホストの追加順＝AppKit側が決める）。
/// 位置・個別ドラッグのズレ・ポヨン・破裂/復活は今までどおりSwiftUIが持つ
struct TripleBallCanvas: View {
    var slot: TripleBubbleCluster.Slot
    var state: AppState
    var settings: SettingsStore
    var cluster: TripleBubbleCluster
    var actions: PanelActions

    /// ウィンドウサイズ（塊 + 漂い・膨張の余白）
    static let windowSize = CGSize(width: 220, height: 210)

    var body: some View {
        ZStack {
            if !cluster.contentParked, !cluster.poppedSlots.contains(slot.index) {
                ball
            }
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        // 再表示のたびにビューを作り直して中身のアニメーションを始め直す
        // （隠している間にレンダーサーバから破棄された宣言的アニメーションは戻らない）
        .id(cluster.showGeneration)
    }

    private var ball: some View {
        BubbleFace(
            slot: slot,
            diameter: cluster.diameter(for: slot, state: state),
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
        .contextMenu {
            #if DEBUG
            Button(forceLegacyUI ? "検証: 旧OS表示 → 通常へ戻す" : "検証: 旧OS表示に切り替え") {
                actions.toggleLegacy()
            }
            Divider()
            #endif
            Button(L("bubble.expandToPanel")) { actions.expand() }
            Button(L("bubble.closeBubble")) { actions.toBubble() }
            Divider()
            Button(L("bubble.settingsMenu")) { actions.settings() }
            Button(L("bubble.quit")) { actions.quit() }
        }
        .help(L("bubble.helpTriple"))
    }
}

/// 球1つぶんの見た目。単体バブル（BubbleView）と同じレイヤー構成を
/// 基準径72pt=1のスケール s で一律に拡縮する（＝単体を別の大きさで描いたもの）。
/// 装飾の .screen / .plusLighter はガラスが同じ合成文脈の背後にいるときだけ
/// 加算で効くので、drawingGroup で焼いてはいけない（光ではなく白い膜になる）。
/// ガラスは単体バブルと同じ SingleBubbleGlass（背景に敷く）
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
        //   ガラス(背景) → 拡散照明 → 文字 → 光沢/虹 → リング
        ZStack {
            ZStack {
                BubbleDepthUnderlay(s: s)
                    .bubbleClarity()
                // 旧OSだけ、文字の裏にぼかしグレーを敷く（26は自動反転で足りる）
                BubbleTextPlate(s: s)
                // 中身のゆらぎ（WobbleHost）は廃止（2026-08-28ユーザー判断）。
                // ガラスを content 側へ掛ける構成では描画に出ないため
                Group {
                    VStack(spacing: 0) {
                        if isPrimary {
                            // 主役のセッションだけロゴを出す（小さい球は%だけで詰まらせない）。
                            // サイズは単体バブルと同じ16pt
                            ClaudeLogoView(
                                animating: state.isActive,
                                color: state.isActive ? .claudeOrange : Color.primary.opacity(0.72)
                            )
                            .frame(width: 16, height: 16)
                        }
                        Text(percentText)
                            // 文字だけは球の大きさに比例させない（50pt球で9ptまで落ちて読めなくなる）。
                            // 単体バブルが膨らんでも文字サイズを固定するのと同じ考え方
                            .font(.system(size: isPrimary ? 13 : 11))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.4), value: percentText)
                            .modifier(BubbleTextHalo(colorScheme: colorScheme))
                        Text(slot.caption(fableLabel: state.fableLabel))
                            .font(.system(size: isPrimary ? 9 : 8))
                            .foregroundStyle(.primary.opacity(0.75))
                            .modifier(BubbleTextHalo(colorScheme: colorScheme))
                    }
                }
                // 光沢・虹はガラスと同じ合成文脈に置く（.screen加算はガラスが
                // 背後にいる時だけ「光」として効く。切り離すと透明背景に対して
                // フル彩度で乗る）
                BubbleShadingOverlay(s: s, strength: BubbleShadingStrength.scaled(for: colorScheme))
                BubbleGlossOverlay(s: s)

                // 使用量リング。単体バブル（72ptで線幅4・余白4）と同じ比率。
                // 虹より前面に置き、ゲージの色が虹に染まらないようにする
                Circle()
                    .trim(from: 0, to: max(0.003, min(value, 100) / 100))
                    .stroke(
                        LinearGradient(colors: [tint, tint.ringDeepened],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 3.4 * s, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(4 * s)
            }
            .padding(3 * s)
            .frame(width: diameter, height: diameter)
            // ガラスは1つ表示と同じ SingleBubbleGlass（content へ掛ける）。
            // これでシステムの「小さい要素は背景に応じて light/dark を反転し、
            // 上に載る文字も一緒に反転する」挙動に乗る
            .modifier(SingleBubbleGlass())
        }
    }
}

