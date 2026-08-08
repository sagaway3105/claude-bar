import SwiftUI

/// トリプルバブル（設計は TRIPLE_BUBBLE.md）。
///
/// 3つの使用量（セッション / Fable週間 / 週間すべて）を重要度順の大きさで浮かべ、
/// 近づくと表面張力のようにくっつく。
///
/// 描画方式はPhase 0の実測で決定（詳細はTRIPLE_BUBBLE.md）:
/// - macOS 26: `GlassEffectContainer(spacing:)` にCircleのglassEffectを入れ、位置だけ動かす。
///   融合はAppleのレンダラが担当する（自前メタボール+glassEffectの半分以下のコスト）
/// - macOS 14/15: 各球は固定形状のすりガラス、くびれは背景を参照しない静的な板で描く
///   （バックドロップ参照層に毎フレーム変わる形状を渡すと極端に重くなるため）
///
/// 漂いの駆動もOSで分かれる。macOS 26はSwiftUIの宣言的アニメーション（repeatForever）に委ねて
/// 毎フレームのCPU再計算を避けるが、旧OSは球とくびれを同じ座標から描く必要があるため
/// TimelineView(30fps)で毎フレーム計算する。
struct TripleBubbleView: View {
    var state: AppState
    var settings: SettingsStore
    var cluster: TripleBubbleCluster
    var actions: PanelActions

    /// ウィンドウサイズ（塊 + 漂い・膨張の余白）
    static let windowSize = CGSize(width: 220, height: 210)

    /// 融合が始まる縁の距離。大きいほど「くびれ」が太く粘っこくなる。
    /// 球は密に配置しつつ、ねばりは控えめにして球の輪郭が読めるようにする
    static let mergeSpacing: CGFloat = 16

    var body: some View {
        Group {
            if isModernGlass {
                // 純正の融合。漂いは宣言的アニメーションでレンダーサーバへ委譲（低CPU）
                modernBody
            } else {
                // 旧OS: 球とくびれを同じ座標から描く必要があるため毎フレーム計算する
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    legacyBody(at: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        // 再表示のたびにビューを作り直して漂いを始め直す（隠している間に
        // レンダーサーバから破棄された宣言的アニメーションは自動では戻らない）
        .id(cluster.showGeneration)
        .contextMenu {
            Button("パネルに展開") { actions.expand() }
            Button("バブルを閉じる") { actions.toBubble() }
            Divider()
            Button("設定…") { actions.settings() }
            Button("終了") { actions.quit() }
        }
        .help("ドラッグで移動（強く引くと全体が動きます）・クリックでポヨン・3連打で破裂")
    }

    /// macOS 26のLiquid Glass（純正融合）が使えるか
    private var isModernGlass: Bool {
        if #available(macOS 26.0, *), !forceLegacyUI { return true }
        return false
    }

    /// macOS 26: Appleのレンダラが近接した球を融合する
    private var modernBody: some View {
        ZStack {
            ZStack {
                ForEach(TripleBubbleCluster.Slot.allCases, id: \.self) { slot in
                    if !cluster.poppedSlots.contains(slot.index) {
                        DriftingBall(slot: slot, cluster: cluster) {
                            ballContent(slot)
                        }
                        // 優先度どおりの重なり: セッションが常に手前、週間が最背面。
                        // zIndexはZStackの直接の子に付けないと効かない
                        // （DriftingBallの内側に置くと外のZStackへ伝わらない）
                        .zIndex(Double(TripleBubbleCluster.Slot.allCases.count - slot.index))
                    }
                }
            }
            .modifier(TripleGlassContainer(spacing: Self.mergeSpacing))
            // 虹色リムは融合コンテナの外側に重ねる。コンテナ内に描くと融合ガラスの
            // 曇りに沈んで虹がほぼ見えない（シングルとの質感差の正体）。
            // 位置・スケールは ballContent と同じ式・同じ値で駆動して完全に追従させる
            ForEach(TripleBubbleCluster.Slot.allCases, id: \.self) { slot in
                if !cluster.poppedSlots.contains(slot.index) {
                    DriftingBall(slot: slot, cluster: cluster) {
                        ballRim(slot)
                    }
                    .zIndex(Double(TripleBubbleCluster.Slot.allCases.count - slot.index))
                }
            }
        }
    }

    /// 球の縁の虹（コンテナの上のレイヤー）。変形の連鎖は ballContent と揃える
    private func ballRim(_ slot: TripleBubbleCluster.Slot) -> some View {
        let diameter = cluster.diameter(for: slot, state: state)
        return BubbleIridescentEdge()
            .frame(width: diameter, height: diameter)
            .scaleEffect(cluster.bounceScales[slot.index])
            .position(cluster.home(for: slot))
            .offset(cluster.dragOffsets[slot.index])
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: cluster.dragOffsets[slot.index])
    }

    /// macOS 14/15: 純正の融合が無いため、くびれを自前で描いて繋がって見せる。
    /// 球とくびれを同一時刻の座標から描くので位置が必ず一致する
    private func legacyBody(at time: TimeInterval) -> some View {
        let visible = TripleBubbleCluster.Slot.allCases.filter { !cluster.poppedSlots.contains($0.index) }
        let balls = visible.map { slot in
            Metaball(
                center: cluster.center(for: slot, at: time),
                radius: cluster.diameter(for: slot, state: state) / 2
            )
        }
        return ZStack {
            // くびれ（背景を参照しない静的な塗り。可変形状に背景ブラーを掛けると極端に重くなる）
            MetaballShape(balls: balls, maxNeckGap: Self.mergeSpacing)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.4))
                .overlay(
                    MetaballShape(balls: balls, maxNeckGap: Self.mergeSpacing)
                        .fill(.white.opacity(0.08))
                )
                .allowsHitTesting(false)
            ForEach(Array(visible.enumerated()), id: \.element) { index, slot in
                let diameter = cluster.diameter(for: slot, state: state)
                BubbleFace(slot: slot, diameter: diameter, state: state,
                           settings: settings, isPrimary: slot == .session)
                    .frame(width: diameter, height: diameter)
                    .modifier(AdaptiveBubbleGlass())
                    .overlay(IridescentRim(shape: Circle()).allowsHitTesting(false))
                    .scaleEffect(cluster.bounceScales[slot.index])
                    .position(balls[index].center)
                    .zIndex(Double(TripleBubbleCluster.Slot.allCases.count - slot.index))
            }
        }
    }

    /// 球の中身（%・ロゴ・ハイライト）+ ガラス。融合はコンテナ側が担当する
    @ViewBuilder
    private func ballContent(_ slot: TripleBubbleCluster.Slot) -> some View {
        let diameter = cluster.diameter(for: slot, state: state)
        BubbleFace(
            slot: slot,
            diameter: diameter,
            state: state,
            settings: settings,
            isPrimary: slot == .session
        )
        .frame(width: diameter, height: diameter)
        .modifier(AdaptiveBubbleGlass())
        // 白いグローだけコンテナ内に敷く（薄め: 密着配置では隣の球と重なり、くびれが白く濁る）。
        // 虹色リムはここではなく modernBody がコンテナの外側に重ねる
        .background(
            Circle()
                .fill(Color.white.opacity(0.12))
                .blur(radius: 7)
                .offset(x: 4, y: 5)
        )
        // 重なり順（zIndex）はここではなく modernBody のZStack直下で指定する
        .scaleEffect(cluster.bounceScales[slot.index])
        .opacity(cluster.poppedSlots.contains(slot.index) ? 0 : 1)
        .scaleEffect(cluster.poppedSlots.contains(slot.index) ? 1.25 : 1) // 割れる瞬間に少し膨らむ
        .position(cluster.home(for: slot))
        .offset(cluster.dragOffsets[slot.index])
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: cluster.dragOffsets[slot.index])
    }
}

/// 球1つぶんの漂い。@Stateを球ごとに持ち、自分のonAppearで漂いを始める。
/// 親の共有フラグ方式だと、破裂→復活でビューが作り直された球は
/// フラグ変化に立ち会えずアニメーションが始まらない（＝復活後に静止する）
private struct DriftingBall<Content: View>: View {
    let slot: TripleBubbleCluster.Slot
    let cluster: TripleBubbleCluster
    @ViewBuilder var content: () -> Content
    @State private var drifting = false

    var body: some View {
        content()
            // X/Yを別アニメーションにして、3つが同じ動きに揃わないようにする
            .offset(x: cluster.driftX(for: slot, drifting: drifting))
            .animation(cluster.driftAnimationX(for: slot), value: drifting)
            .offset(y: cluster.driftY(for: slot, drifting: drifting))
            .animation(cluster.driftAnimationY(for: slot), value: drifting)
            .onAppear { drifting = true }
    }
}

/// シングルバブルと同じガラス玉の質感（ヘイズ・球面の照り・コースティクス・ハイライト）。
/// 中身だけ差し替えて使う共通部品で、直径76ptを基準に線幅・ぼかしまで含めて全体をスケールする。
///
/// シングルバブル（BubbleView）は同じ質感を別に持つが、そちらは膨らんでも
/// 線幅・ぼかし・余白を固定して中身の見え方を保つ設計のため、あえて統合していない。
struct BubbleSphere<Content: View>: View {
    var diameter: CGFloat
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    /// 基準径（シングルバブルと同じ72pt）を1としたスケール。
    /// セッション球でシングルと装飾の絶対値が一致する
    private var s: CGFloat { diameter / 72 }

    private var hazeCore: Color {
        colorScheme == .dark ? .black : Color(nsColor: .windowBackgroundColor)
    }
    private var hazeCoreOpacity: Double { colorScheme == .dark ? 0.38 : 0.25 }

    var body: some View {
        ZStack {
            // ヘイズ: 中心に薄い乳白を敷いて文字の下地を安定させる。
            // 縁側はシングルバブル（0.4/0.5）より薄くする — 密着配置では隣の球の縁と
            // 重なって足し算され、くびれが白く濁るため
            Circle()
                .fill(EllipticalGradient(
                    gradient: Gradient(stops: [
                        .init(color: hazeCore.opacity(hazeCoreOpacity), location: 0),
                        .init(color: hazeCore.opacity(hazeCoreOpacity - 0.03), location: 0.4),
                        .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.05), location: 0.65),
                        .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.22), location: 0.88),
                        .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.28), location: 1),
                    ]),
                    center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5
                ))
                .blur(radius: 2)
            // 球面の照り（左上光源）
            Circle()
                .fill(RadialGradient(
                    colors: [.white.opacity(0.15), .white.opacity(0.04), .clear],
                    center: UnitPoint(x: 0.32, y: 0.28),
                    startRadius: 2, endRadius: 46 * s
                ))
            // 上縁の深度シェーディング
            Circle()
                .trim(from: 0.5, to: 1.0)
                .stroke(Color.black.opacity(0.15), style: StrokeStyle(lineWidth: 8 * s, lineCap: .round))
                .blur(radius: 5 * s)
            // 底に溜まる透過光（コースティクス）
            Circle()
                .trim(from: 0.1, to: 0.4)
                .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 9 * s, lineCap: .round))
                .blur(radius: 5 * s)
            Circle()
                .fill(RadialGradient(
                    colors: [.white.opacity(0.35), .clear],
                    center: UnitPoint(x: 0.5, y: 0.9),
                    startRadius: 1, endRadius: 26 * s
                ))

            content()

            // 主ハイライト（大きく柔らかいブルーム + 小さく鋭いスポット）
            Ellipse()
                .fill(.white.opacity(0.55))
                .frame(width: 24 * s, height: 14 * s)
                .rotationEffect(.degrees(-35))
                .offset(x: -13 * s, y: -17 * s)
                .blur(radius: 4 * s)
            Circle()
                .fill(.white.opacity(0.95))
                .frame(width: 6 * s, height: 6 * s)
                .offset(x: -19 * s, y: -13 * s)
                .blur(radius: 0.6)
            // 対向の小さなグリント
            Circle()
                .fill(.white.opacity(0.28))
                .frame(width: 5 * s, height: 5 * s)
                .offset(x: 15 * s, y: 19 * s)
                .blur(radius: 0.8)
        }
        .padding(3 * s)
        .frame(width: diameter, height: diameter)
    }
}

/// 球の中身。ガラス玉の内側に見える情報（融合させない要素）
struct BubbleFace: View {
    var slot: TripleBubbleCluster.Slot
    var diameter: CGFloat
    var state: AppState
    var settings: SettingsStore
    var isPrimary: Bool

    private var window: UsageWindow? { state.usage?.window(for: slot.metric) }
    private var value: Double { window?.utilization ?? 0 }

    private var tint: Color {
        if value >= 95 { return .red }
        if value >= 80 { return .orange }
        return settings.useSystemAccent ? Color(nsColor: .controlAccentColor) : .claudeOrange
    }

    private var percentText: String {
        state.usage == nil ? "–%" : "\(Int(value.rounded()))%"
    }

    var body: some View {
        BubbleSphere(diameter: diameter) {
            ZStack {
                // 使用量リング（シングルバブルと同じく縁から少し内側）
                Circle()
                    .trim(from: 0, to: max(0.003, min(value, 100) / 100))
                    .stroke(
                        LinearGradient(colors: [tint.opacity(0.55), tint],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: isPrimary ? 4 : 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(4)

                VStack(spacing: 0) {
                    if isPrimary {
                        // 主役のセッションだけロゴを出す（小さい球は%だけで詰まらせない）
                        ClaudeLogoView(
                            animating: state.isActive,
                            color: state.isActive ? .claudeOrange : .primary
                        )
                        .frame(width: 15, height: 15)
                    }
                    Text(percentText)
                        .font(.system(size: isPrimary ? 13 : 11))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.4), value: percentText)
                    Text(slot.caption(fableLabel: state.fableLabel))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 融合の器。macOS 26はAppleのレンダラが近接した球をくっつける
/// （spacingは明示必須 — 既定値0/nilでは融合せず性能最適化だけが働く）
private struct TripleGlassContainer: ViewModifier {
    var spacing: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !forceLegacyUI {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
