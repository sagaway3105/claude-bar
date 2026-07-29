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
/// 漂いはSwiftUIの宣言的アニメーション（repeatForever）に委ね、毎フレームのCPU再計算を避ける。
struct TripleBubbleView: View {
    var state: AppState
    var settings: SettingsStore
    var cluster: TripleBubbleCluster
    var actions: PanelActions

    @State private var drifting = false

    /// ウィンドウサイズ（塊 + 漂い・膨張の余白）
    static let windowSize = CGSize(width: 220, height: 210)

    /// 融合が始まる縁の距離。大きいほど「くびれ」が太く粘っこくなる。
    /// 球は密に配置しつつ、ねばりは控えめにして球の輪郭が読めるようにする
    static let mergeSpacing: CGFloat = 16

    var body: some View {
        ZStack {
            // 旧OSは純正の融合が無いので、くびれを自前で描いて繋がって見せる
            if !isModernGlass {
                LegacyNeckLayer(cluster: cluster, state: state, drifting: drifting)
            }
            ForEach(TripleBubbleCluster.Slot.allCases, id: \.self) { slot in
                if !cluster.poppedSlots.contains(slot.index) {
                    ballContent(slot)
                }
            }
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .modifier(TripleGlassContainer(spacing: Self.mergeSpacing))
        .onAppear { drifting = true }
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
        .modifier(BallGlass())
        // シングルバブルと同じ縁の表現（内側へにじむ虹色フリンジ + 虹色リム）
        .overlay(
            ZStack {
                Circle()
                    .strokeBorder(
                        AngularGradient(colors: [
                            .cyan.opacity(0.3), .purple.opacity(0.24), .pink.opacity(0.28),
                            .orange.opacity(0.22), .mint.opacity(0.26), .cyan.opacity(0.3),
                        ], center: .center),
                        lineWidth: 4
                    )
                    .blur(radius: 3)
                    .opacity(0.7)
                IridescentRim(shape: Circle())
            }
            .allowsHitTesting(false)
        )
        // 微かな白いドロップシャドウ（シングルバブルと同じ右下へのグロー）
        .background(
            Circle()
                .fill(Color.white.opacity(0.25))
                .blur(radius: 7)
                .offset(x: 4, y: 5)
        )
        // 優先度どおりの重なり: セッションが常に手前、週間が最背面。
        // 融合しても重要な球のゲージ・数字が隠れない
        .zIndex(Double(TripleBubbleCluster.Slot.allCases.count - slot.index))
        .scaleEffect(cluster.bounceScales[slot.index])
        .opacity(cluster.poppedSlots.contains(slot.index) ? 0 : 1)
        .scaleEffect(cluster.poppedSlots.contains(slot.index) ? 1.25 : 1) // 割れる瞬間に少し膨らむ
        .position(cluster.home(for: slot))
        // X/Yを別アニメーションにして、3つが同じ動きに揃わないようにする
        .offset(x: cluster.driftX(for: slot, drifting: drifting))
        .animation(cluster.driftAnimationX(for: slot), value: drifting)
        .offset(y: cluster.driftY(for: slot, drifting: drifting))
        .animation(cluster.driftAnimationY(for: slot), value: drifting)
        .offset(cluster.dragOffsets[slot.index])
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: cluster.dragOffsets[slot.index])
    }
}

/// シングルバブルと同じガラス玉の質感（ヘイズ・球面の照り・コースティクス・
/// ハイライト・虹色リム）。中身だけ差し替えて使う共通部品。
/// 直径76ptを基準にすべての装飾をスケールする
struct BubbleSphere<Content: View>: View {
    var diameter: CGFloat
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    /// 76ptを1としたスケール
    private var s: CGFloat { diameter / 76 }

    private var hazeCore: Color {
        colorScheme == .dark ? .black : Color(nsColor: .windowBackgroundColor)
    }
    private var hazeCoreOpacity: Double { colorScheme == .dark ? 0.38 : 0.25 }

    var body: some View {
        ZStack {
            // ヘイズ: 中心に薄い乳白を敷いて文字の下地を安定させる
            Circle()
                .fill(EllipticalGradient(
                    gradient: Gradient(stops: [
                        .init(color: hazeCore.opacity(hazeCoreOpacity), location: 0),
                        .init(color: hazeCore.opacity(hazeCoreOpacity - 0.03), location: 0.4),
                        .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.06), location: 0.65),
                        .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.4), location: 0.88),
                        .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.5), location: 1),
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

/// 球1つぶんのガラス。形状はCircle固定（システムが標準プリミティブへ解決するため）
private struct BallGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !forceLegacyUI {
            content.glassEffect(.clear, in: Circle())
        } else {
            content.background(Circle().fill(.ultraThinMaterial))
        }
    }
}

/// 旧OS（macOS 14/15）用のくびれ。純正の融合が無いため自前のメタボール形状で繋ぐ。
/// 背景を参照しない静的な塗りにして、可変形状に背景ブラーを掛ける高コストを避ける
private struct LegacyNeckLayer: View {
    var cluster: TripleBubbleCluster
    var state: AppState
    var drifting: Bool

    var body: some View {
        let balls = TripleBubbleCluster.Slot.allCases
            .filter { !cluster.poppedSlots.contains($0.index) }
            .map { slot -> Metaball in
            let home = cluster.home(for: slot)
            let offset = cluster.offset(for: slot, drifting: drifting)
            return Metaball(
                center: CGPoint(x: home.x + offset.width, y: home.y + offset.height),
                radius: cluster.diameter(for: slot, state: state) / 2
            )
        }
        MetaballShape(balls: balls, maxNeckGap: TripleBubbleView.mergeSpacing)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
            .overlay(
                MetaballShape(balls: balls, maxNeckGap: TripleBubbleView.mergeSpacing)
                    .fill(.white.opacity(0.10))
            )
            .allowsHitTesting(false)
    }
}
