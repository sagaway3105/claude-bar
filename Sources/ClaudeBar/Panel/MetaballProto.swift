#if DEBUG
import AppKit
import QuartzCore
import SwiftUI

/// トリプルバブル（TRIPLE_BUBBLE.md）Phase 0の負荷検証用プロトタイプ。
/// メタボールのネックを毎フレーム再計算しながら描いた時に60fpsを保てるかを実測する。
/// デバッグビルド限定・製品UIには一切現れない。
enum ProtoConfig: String, CaseIterable {
    case circles  // 3円の塗りのみ（基準値）
    case necks    // 3円+ネック（nonZero塗り）
    case union    // ネック+union輪郭のストローク
    case glass    // 本番候補: ガラス+リム+ヘイズ+球ごとのハイライト
    case glass30  // 本番候補を30fps駆動（省電力案）
    case legacy   // 旧OSフォールバック（ultraThinMaterial）

    /// 描画レート。nilは表示リフレッシュレート
    var minimumInterval: Double? { self == .glass30 ? 1.0 / 30.0 : nil }
}

/// フレーム数を数えるだけの器（Observableにするとbody内tickで更新ループになるため素のclass）
@MainActor
final class ProtoFrameCounter {
    static let shared = ProtoFrameCounter()
    private var stamps: [CFTimeInterval] = []

    func tick() {
        let now = CACurrentMediaTime()
        stamps.append(now)
        while let first = stamps.first, now - first > 1.0 { stamps.removeFirst() }
    }

    /// 直近1秒の実効フレームレート
    var fps: Int { stamps.count }

    func reset() { stamps.removeAll() }
}

struct MetaballProtoView: View {
    var config: ProtoConfig

    // ホーム位置。上からセッション→Fable→週間（重要度順）だが、真っ直ぐ縦には並べず
    // 左右へ振ったジグザグにして塊をなるべく小さくまとめる。隣同士はわずかに重なる距離
    private let homes: [CGPoint] = [
        CGPoint(x: 150, y: 104), // セッション（最上・最大・やや左）
        CGPoint(x: 194, y: 156), // Fable（右へ振る）
        CGPoint(x: 154, y: 200), // 週間（最下・最小・左へ戻す）
    ]
    private let radii: [CGFloat] = [38, 32, 27]
    private let tints: [Color] = [.claudeOrange, .orange, .cyan]

    /// 常にくっついたり離れたりを繰り返す最悪ケースの漂い（振幅は本番想定より大きめ）
    private func balls(at t: TimeInterval) -> [Metaball] {
        homes.enumerated().map { index, home in
            let phase = Double(index) * 1.7
            let dx = sin(t * 0.9 + phase) * 9 + sin(t * 0.53 + phase) * 4
            let dy = cos(t * 0.74 + phase) * 9 + sin(t * 0.41 + phase) * 4
            return Metaball(
                center: CGPoint(x: home.x + dx, y: home.y + dy),
                radius: radii[index]
            )
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: config.minimumInterval)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let balls = balls(at: t)
            let shape = MetaballShape(balls: balls)
            content(shape: shape, balls: balls)
                .background(FrameTick(t: t))
        }
        .frame(width: 360, height: 300)
    }

    @ViewBuilder
    private func content(shape: MetaballShape, balls: [Metaball]) -> some View {
        switch config {
        case .circles:
            ZStack {
                ForEach(balls.indices, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: balls[i].radius * 2, height: balls[i].radius * 2)
                        .position(balls[i].center)
                }
            }
        case .necks:
            shape.fill(Color.white.opacity(0.35))
        case .union:
            ZStack {
                shape.fill(Color.white.opacity(0.35))
                shape.outlinePath(in: .zero)
                    .stroke(Color.cyan.opacity(0.6), lineWidth: 1.5)
            }
        case .glass, .glass30:
            glassBody(shape: shape, balls: balls)
        case .legacy:
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.outlinePath(in: .zero)
                    .stroke(Color.cyan.opacity(0.5), lineWidth: 1.5)
                perBallDetails(balls)
            }
        }
    }

    /// 本番候補の構成: 融合シルエットでガラスを描き、ハイライト類は球ごとに残す
    @ViewBuilder
    private func glassBody(shape: MetaballShape, balls: [Metaball]) -> some View {
        let outline = shape.outlinePath(in: .zero)
        ZStack {
            // 下地ヘイズ（融合シルエット）
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.25))
                .blur(radius: 2)
            // 虹色リム（融合輪郭に沿う）
            outline.stroke(
                AngularGradient(colors: [
                    .cyan.opacity(0.3), .purple.opacity(0.24), .pink.opacity(0.28),
                    .orange.opacity(0.22), .mint.opacity(0.26), .cyan.opacity(0.3),
                ], center: .center),
                lineWidth: 3
            )
            .blur(radius: 2)
            outline.stroke(.white.opacity(0.25), lineWidth: 0.8)
            perBallDetails(balls)
        }
        .modifier(ProtoGlass(shape: shape))
    }

    /// 球体感を担うハイライト・照り・%文字（融合させず球ごとに描く）
    @ViewBuilder
    private func perBallDetails(_ balls: [Metaball]) -> some View {
        ForEach(balls.indices, id: \.self) { i in
            let r = balls[i].radius
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [.white.opacity(0.15), .white.opacity(0.04), .clear],
                        center: UnitPoint(x: 0.32, y: 0.28),
                        startRadius: 2, endRadius: r * 1.2
                    ))
                Ellipse()
                    .fill(.white.opacity(0.55))
                    .frame(width: r * 0.62, height: r * 0.36)
                    .rotationEffect(.degrees(-35))
                    .offset(x: -r * 0.34, y: -r * 0.45)
                    .blur(radius: 4)
                Text("\(Int(r))%")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(tints[i])
            }
            .frame(width: r * 2, height: r * 2)
            .position(balls[i].center)
        }
    }
}

/// 形状が毎フレーム変わる状態でのガラス描画コスト測定用
private struct ProtoGlass: ViewModifier {
    var shape: MetaballShape

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !forceLegacyUI {
            content.glassEffect(.clear, in: shape)
        } else {
            content.background(shape.fill(.ultraThinMaterial))
        }
    }
}

/// TimelineViewの再評価ごとにフレーム数を刻む（bodyの副作用でstateを触らないための小細工）。
/// tを持たせないとSwiftUIが「入力不変」と判断してupdateNSViewを呼ばず計測できない
private struct FrameTick: NSViewRepresentable {
    var t: TimeInterval

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        ProtoFrameCounter.shared.tick()
    }
}

/// プロトタイプ用の透明ウィンドウ
@MainActor
final class MetaballProtoWindow {
    static let shared = MetaballProtoWindow()
    private var window: NSWindow?
    private(set) var config: ProtoConfig = .glass

    func show(config: ProtoConfig) {
        self.config = config
        ProtoFrameCounter.shared.reset()
        let hosting = NSHostingView(rootView: MetaballProtoView(config: config))
        if let window {
            window.contentView = hosting
            window.orderFrontRegardless()
            return
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = NSWindow(
            contentRect: NSRect(x: screen.midX - 180, y: screen.midY - 150, width: 360, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.contentView = hosting
        w.orderFrontRegardless()
        window = w
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }

    var isVisible: Bool { window?.isVisible ?? false }
}
#endif
