import AppKit
import SwiftUI

// Phase 0 単独ベンチ: ClaudeBar本体の常時活動（FSEvents/ロゴアニメ）を含まない
// クリーンな環境でメタボール描画のCPUコストとフレームレートを測る。
// 自プロセスのCPU時間を getrusage で直接読むため外部ノイズの影響を受けない。

let forceLegacyUI = ProcessInfo.processInfo.environment["FORCE_LEGACY"] == "1"

enum BenchConfig: String, CaseIterable {
    case none      // 空ウィンドウ（基準値）
    case circles   // 3円の塗りのみ
    case necks     // 3円+ネック（nonZero塗り）
    case union     // ネック+union輪郭のストローク
    case glass     // 本番候補: ガラス+リム+ヘイズ+球ごとの装飾
    case glass30   // 同上を30fps駆動
    case maskGlass // ブラーは固定領域・マスクだけ動かす案
    case legacy    // 旧OS想定（ultraThinMaterial）
    case singleCA  // 【比較基準】現行の単一バブル相当（CAAnimation駆動・融合なし）
    case tripleCA  // 3球をCAAnimation駆動で個別ガラス（融合なし）
    case container     // 【純正融合】GlassEffectContainerに3球（TimelineViewで毎フレーム移動）
    case containerAnim // 同上をSwiftUI宣言的アニメ（repeatForever）で動かす省電力案
    case containerFull // 本番候補: 純正融合 + 自前リム + 球ごとの装飾
    case canvasMask    // 【旧OS本命】固定ガラス板をCanvas(blur+alphaThreshold)でマスク
    case canvasShape   // 同上のマスクを自前メタボールPathで作る版（エッジが滑らか）

    var minimumInterval: Double? { self == .glass30 ? 1.0 / 30.0 : nil }

    /// CoreAnimation駆動（TimelineViewを使わない）構成か
    var isCADriven: Bool { self == .singleCA || self == .tripleCA }
}

final class FrameCounter {
    static let shared = FrameCounter()
    private var stamps: [CFTimeInterval] = []
    func tick() {
        let now = CACurrentMediaTime()
        stamps.append(now)
        while let f = stamps.first, now - f > 1.0 { stamps.removeFirst() }
    }
    var fps: Int { stamps.count }
    func reset() { stamps.removeAll() }
}

struct FrameTick: NSViewRepresentable {
    var t: TimeInterval
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { FrameCounter.shared.tick() }
}

struct BenchView: View {
    var config: BenchConfig

    private let homes: [CGPoint] = [
        CGPoint(x: 150, y: 104),
        CGPoint(x: 194, y: 156),
        CGPoint(x: 154, y: 200),
    ]
    private let radii: [CGFloat] = [38, 32, 27]

    private func balls(at t: TimeInterval) -> [Metaball] {
        homes.enumerated().map { index, home in
            let phase = Double(index) * 1.7
            let dx = sin(t * 0.9 + phase) * 9 + sin(t * 0.53 + phase) * 4
            let dy = cos(t * 0.74 + phase) * 9 + sin(t * 0.41 + phase) * 4
            return Metaball(center: CGPoint(x: home.x + dx, y: home.y + dy), radius: radii[index])
        }
    }

    var body: some View {
        if config == .none {
            Color.clear.frame(width: 360, height: 300)
        } else if config.isCADriven {
            // 現行方式: 浮遊はレンダーサーバ側のCAAnimationに委譲し、
            // SwiftUI側は球の中身（30fps）だけを描く
            CAFloatingBalls(
                count: config == .singleCA ? 1 : 3,
                homes: homes, radii: radii
            )
            .frame(width: 360, height: 300)
        } else if config == .container {
            ContainerGlassBalls(homes: homes, radii: radii)
                .frame(width: 360, height: 300)
        } else if config == .containerAnim {
            ContainerAnimatedBalls(homes: homes, radii: radii, decorated: false)
                .frame(width: 360, height: 300)
        } else if config == .containerFull {
            ContainerAnimatedBalls(homes: homes, radii: radii, decorated: true)
                .frame(width: 360, height: 300)
        } else {
            TimelineView(.animation(minimumInterval: config.minimumInterval)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let balls = balls(at: t)
                let shape = MetaballShape(balls: balls)
                content(shape: shape, balls: balls)
                    .background(FrameTick(t: t))
            }
            .frame(width: 360, height: 300)
        }
    }

    @ViewBuilder
    private func content(shape: MetaballShape, balls: [Metaball]) -> some View {
        switch config {
        case .none, .singleCA, .tripleCA, .container, .containerAnim, .containerFull:
            EmptyView() // これらはbody側で別経路を通る
        case .circles:
            ZStack {
                ForEach(balls.indices, id: \.self) { i in
                    Circle().fill(Color.white.opacity(0.35))
                        .frame(width: balls[i].radius * 2, height: balls[i].radius * 2)
                        .position(balls[i].center)
                }
            }
        case .necks:
            shape.fill(Color.white.opacity(0.35))
        case .union:
            ZStack {
                shape.fill(Color.white.opacity(0.35))
                shape.outlinePath(in: .zero).stroke(Color.cyan.opacity(0.6), lineWidth: 1.5)
            }
        case .glass, .glass30:
            decorated(shape: shape, balls: balls).modifier(BenchGlass(shape: shape))
        case .maskGlass:
            // ブラー領域は固定（画面全体を覆う静的なガラス）にして、
            // 毎フレーム変わるのはマスク形状だけ。背景の再サンプリングを避けられるかの検証
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                    .mask(shape.fill(Color.black))
                decorated(shape: shape, balls: balls)
            }
        case .legacy:
            ZStack {
                shape.fill(.ultraThinMaterial)
                decorated(shape: shape, balls: balls)
            }
        case .canvasMask, .canvasShape:
            // リサーチ推奨の層構成:
            //  ① バックドロップを参照する層は固定形状のまま（マスクを掛けない）
            //  ② その上に背景を参照しない「ガラス板」を静的に置く
            //  ③ ②だけをメタボール形状でマスクする（毎フレーム変わるのはマスクだけ）
            ZStack {
                GlassPlate()
                    .compositingGroup()
                    .mask {
                        if config == .canvasMask {
                            MetaballCanvasMask(balls: balls)
                        } else {
                            shape.fill(Color.black)
                        }
                    }
                ballOverlays(balls) // 融合させたくない要素はマスクの外
            }
        }
    }

    /// 球ごとのハイライト・照り・%（融合させず個別に描く）
    @ViewBuilder
    private func ballOverlays(_ balls: [Metaball]) -> some View {
        ForEach(balls.indices, id: \.self) { i in
            let r = balls[i].radius
            ZStack {
                Ellipse().fill(.white.opacity(0.55))
                    .frame(width: r * 0.62, height: r * 0.36)
                    .rotationEffect(.degrees(-35))
                    .offset(x: -r * 0.34, y: -r * 0.45).blur(radius: 4)
                Text("\(Int(r))%").font(.system(size: 13)).monospacedDigit()
            }
            .frame(width: r * 2, height: r * 2)
            .position(balls[i].center)
        }
    }

    @ViewBuilder
    private func decorated(shape: MetaballShape, balls: [Metaball]) -> some View {
        let outline = shape.outlinePath(in: .zero)
        ZStack {
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.25)).blur(radius: 2)
            outline.stroke(
                AngularGradient(colors: [
                    .cyan.opacity(0.3), .purple.opacity(0.24), .pink.opacity(0.28),
                    .orange.opacity(0.22), .mint.opacity(0.26), .cyan.opacity(0.3),
                ], center: .center),
                lineWidth: 3
            ).blur(radius: 2)
            outline.stroke(.white.opacity(0.25), lineWidth: 0.8)
            ForEach(balls.indices, id: \.self) { i in
                let r = balls[i].radius
                ZStack {
                    Circle().fill(RadialGradient(
                        colors: [.white.opacity(0.15), .white.opacity(0.04), .clear],
                        center: UnitPoint(x: 0.32, y: 0.28), startRadius: 2, endRadius: r * 1.2))
                    Ellipse().fill(.white.opacity(0.55))
                        .frame(width: r * 0.62, height: r * 0.36)
                        .rotationEffect(.degrees(-35))
                        .offset(x: -r * 0.34, y: -r * 0.45).blur(radius: 4)
                    Text("\(Int(r))%").font(.system(size: 13)).monospacedDigit()
                }
                .frame(width: r * 2, height: r * 2)
                .position(balls[i].center)
            }
        }
    }
}

/// 単体のガラス玉（現行BubbleView相当の中身: ガラス+リム+ハイライト+30fpsの文字）
struct GlassBall: View {
    var radius: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.25)).blur(radius: 2)
                Circle().fill(RadialGradient(
                    colors: [.white.opacity(0.15), .white.opacity(0.04), .clear],
                    center: UnitPoint(x: 0.32, y: 0.28), startRadius: 2, endRadius: radius * 1.2))
                Ellipse().fill(.white.opacity(0.55))
                    .frame(width: radius * 0.62, height: radius * 0.36)
                    .rotationEffect(.degrees(-35))
                    .offset(x: -radius * 0.34, y: -radius * 0.45).blur(radius: 4)
                Text("\(Int(radius))%").font(.system(size: 13)).monospacedDigit()
                    .rotationEffect(.degrees(sin(t * 0.9) * 3))
            }
            .frame(width: radius * 2, height: radius * 2)
            .modifier(CircleGlass())
            .overlay(
                Circle().strokeBorder(
                    AngularGradient(colors: [
                        .cyan.opacity(0.3), .purple.opacity(0.24), .pink.opacity(0.28),
                        .orange.opacity(0.22), .mint.opacity(0.26), .cyan.opacity(0.3),
                    ], center: .center), lineWidth: 1.5)
            )
        }
    }
}

struct CircleGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !forceLegacyUI {
            content.glassEffect(.clear, in: Circle())
        } else {
            content.background(Circle().fill(.ultraThinMaterial))
        }
    }
}

/// 現行方式の再現: 浮遊をレンダーサーバのCAAnimationに委譲する
struct CAFloatingBalls: NSViewRepresentable {
    var count: Int
    var homes: [CGPoint]
    var radii: [CGFloat]

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
        container.wantsLayer = true
        for i in 0..<count {
            let r = radii[i]
            let assembly = NSView(frame: NSRect(
                x: homes[i].x - r, y: 300 - homes[i].y - r, width: r * 2, height: r * 2))
            assembly.wantsLayer = true
            let hosting = NSHostingView(rootView: GlassBall(radius: r))
            hosting.frame = assembly.bounds
            hosting.autoresizingMask = []
            assembly.addSubview(hosting)
            container.addSubview(assembly)
            if let layer = assembly.layer {
                addFloat(to: layer, phase: Double(i) * 1.7)
            }
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// 製品版と同じ「周期の異なる正弦波を加算合成した無限アニメーション」
    private func addFloat(to layer: CALayer, phase: Double) {
        func animation(_ keyPath: String, _ amplitude: CGFloat, _ duration: CFTimeInterval,
                       _ offset: CFTimeInterval) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: keyPath)
            a.fromValue = -amplitude
            a.toValue = amplitude
            a.duration = duration
            a.autoreverses = true
            a.repeatCount = .infinity
            a.isAdditive = true
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.timeOffset = duration / 2 + offset
            return a
        }
        layer.add(animation("position.x", 6, 3.7, phase), forKey: "float-x1")
        layer.add(animation("position.x", 2.5, 6.1, phase + 1.7), forKey: "float-x2")
        layer.add(animation("position.y", 7, 4.4, phase + 1.1), forKey: "float-y1")
        layer.add(animation("position.y", 2.5, 7.9, phase + 3.0), forKey: "float-y2")
    }
}

/// Apple純正の融合: GlassEffectContainer内で近接したglassEffectが自動的にくっつくか検証
struct ContainerGlassBalls: View {
    var homes: [CGPoint]
    var radii: [CGFloat]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            containerBody(t: t)
                .background(FrameTick(t: t))
        }
    }

    @ViewBuilder
    private func containerBody(t: TimeInterval) -> some View {
        if #available(macOS 26.0, *), !forceLegacyUI {
            GlassEffectContainer(spacing: 24) {
                ZStack {
                    ForEach(homes.indices, id: \.self) { i in
                        let phase = Double(i) * 1.7
                        let dx = sin(t * 0.9 + phase) * 9 + sin(t * 0.53 + phase) * 4
                        let dy = cos(t * 0.74 + phase) * 9 + sin(t * 0.41 + phase) * 4
                        Circle()
                            .fill(Color.clear)
                            .frame(width: radii[i] * 2, height: radii[i] * 2)
                            .glassEffect(.clear, in: Circle())
                            .position(x: homes[i].x + dx, y: homes[i].y + dy)
                    }
                }
            }
        } else {
            Text("macOS 26専用")
        }
    }
}

/// 純正融合 + SwiftUI宣言的アニメーション（毎フレームのCPU再計算を避ける狙い）。
/// decorated=true で本番想定の装飾（リム・ハイライト・%）も乗せる
struct ContainerAnimatedBalls: View {
    var homes: [CGPoint]
    var radii: [CGFloat]
    var decorated: Bool
    @State private var drifting = false

    // 球ごとに違う振幅・周期にして有機的に見せる
    private let amplitudes: [CGSize] = [
        CGSize(width: 7, height: 9),
        CGSize(width: -9, height: 6),
        CGSize(width: 6, height: -8),
    ]
    private let durations: [Double] = [3.7, 4.6, 5.3]

    var body: some View {
        content
            .onAppear { drifting = true }
    }

    @ViewBuilder
    private var content: some View {
        if #available(macOS 26.0, *), !forceLegacyUI {
            GlassEffectContainer(spacing: 24) {
                ZStack {
                    ForEach(homes.indices, id: \.self) { i in
                        ballView(i)
                            .glassEffect(.clear, in: Circle())
                            .offset(
                                x: drifting ? amplitudes[i].width : -amplitudes[i].width,
                                y: drifting ? amplitudes[i].height : -amplitudes[i].height
                            )
                            .animation(
                                .easeInOut(duration: durations[i]).repeatForever(autoreverses: true),
                                value: drifting
                            )
                            .position(homes[i])
                    }
                }
            }
        } else {
            Text("macOS 26専用")
        }
    }

    @ViewBuilder
    private func ballView(_ i: Int) -> some View {
        let r = radii[i]
        if decorated {
            ZStack {
                Circle().fill(RadialGradient(
                    colors: [.white.opacity(0.15), .white.opacity(0.04), .clear],
                    center: UnitPoint(x: 0.32, y: 0.28), startRadius: 2, endRadius: r * 1.2))
                Ellipse().fill(.white.opacity(0.55))
                    .frame(width: r * 0.62, height: r * 0.36)
                    .rotationEffect(.degrees(-35))
                    .offset(x: -r * 0.34, y: -r * 0.45).blur(radius: 4)
                Text("\(Int(r))%").font(.system(size: 13)).monospacedDigit()
            }
            .frame(width: r * 2, height: r * 2)
            .overlay(
                Circle().strokeBorder(
                    AngularGradient(colors: [
                        .cyan.opacity(0.3), .purple.opacity(0.24), .pink.opacity(0.28),
                        .orange.opacity(0.22), .mint.opacity(0.26), .cyan.opacity(0.3),
                    ], center: .center), lineWidth: 1.5)
            )
        } else {
            Circle().fill(Color.clear).frame(width: r * 2, height: r * 2)
        }
    }
}

struct BenchGlass: ViewModifier {
    var shape: MetaballShape
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !forceLegacyUI {
            content.glassEffect(.clear, in: shape)
        } else {
            content.background(shape.fill(.ultraThinMaterial))
        }
    }
}

/// 背景を参照しない静的な「ガラス板」。毎フレーム変わらないのでキャッシュが効く
struct GlassPlate: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.white.opacity(0.28), .white.opacity(0.10), .white.opacity(0.20)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [.white.opacity(0.30), .clear],
                center: UnitPoint(x: 0.3, y: 0.25), startRadius: 4, endRadius: 160
            )
        }
    }
}

/// Canvas + blur + alphaThreshold による古典的グーイー（メタボール）マスク。
/// 円をぼかして閾値で切ることで、近接した円が自然にくっついた形になる
struct MetaballCanvasMask: View {
    var balls: [Metaball]

    var body: some View {
        Canvas { context, _ in
            context.addFilter(.alphaThreshold(min: 0.5, color: .black))
            context.addFilter(.blur(radius: 12))
            context.drawLayer { layer in
                for (index, ball) in balls.enumerated() {
                    guard let symbol = context.resolveSymbol(id: index) else { continue }
                    layer.draw(symbol, at: ball.center)
                }
            }
        } symbols: {
            ForEach(balls.indices, id: \.self) { i in
                Circle()
                    .fill(Color.black)
                    .frame(width: balls[i].radius * 2, height: balls[i].radius * 2)
                    .tag(i)
            }
        }
    }
}

/// ガラスの屈折・融合が目視できるようにする検証用の背景
struct CheckerBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.orange, .pink, .purple, .blue, .teal],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 14) {
                ForEach(0..<16, id: \.self) { _ in
                    Text("ClaudeBar 使用量 12% 34% 56%")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
    }
}

/// 自プロセスの累積CPU時間(秒)
func processCPUSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    return user + sys
}

@MainActor
final class BenchRunner {
    static let shared = BenchRunner()
    private var window: NSWindow?
    private var backdrop: NSWindow?
    private var results: [(String, Int, Double)] = []
    private let sampleSeconds: Double = 5.0

    func run() {
        Task { @MainActor in
            // ウィンドウを1枚作り、構成を差し替えながら測る
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            // HOLD=<構成名> で1構成だけ表示し続ける（目視/スクリーンショット確認用）
            if let hold = ProcessInfo.processInfo.environment["HOLD"],
               let config = BenchConfig(rawValue: hold) {
                // 撮影を確実にするため、メニューバーのあるディスプレイ(screens[0]、原点(0,0))の
                // 左上から一定の位置に固定で出す → screencapture -R の座標が自明になる
                let zero = NSScreen.screens[0].frame
                let w = NSWindow(
                    contentRect: NSRect(x: zero.origin.x + 60,
                                        y: zero.origin.y + zero.height - 60 - 300,
                                        width: 360, height: 300),
                    styleMask: .borderless, backing: .buffered, defer: false
                )
                w.backgroundColor = .clear
                w.isOpaque = false
                w.hasShadow = false
                w.ignoresMouseEvents = true
                w.level = .floating
                w.contentView = NSHostingView(rootView: BenchView(config: config))
                // ガラスの融合が見えるよう、背後に模様のある窓を敷く
                let bg = NSWindow(
                    contentRect: w.frame.insetBy(dx: -20, dy: -20),
                    styleMask: .borderless, backing: .buffered, defer: false
                )
                bg.backgroundColor = .clear
                bg.isOpaque = false
                bg.hasShadow = false
                bg.ignoresMouseEvents = true
                bg.level = .normal
                bg.contentView = NSHostingView(rootView: CheckerBackdrop())
                bg.orderFrontRegardless()
                backdrop = bg

                w.orderFrontRegardless()
                window = w
                // screencapture -R 用の矩形（メインディスプレイ左上原点・y下向き）に変換して出す
                // 窓が載っているディスプレイと、その左上原点での位置（pt）を出す
                // 固定配置なので撮影矩形も自明（screens[0]左上から60,60）
                print("CAP:60,60,360,300")
                fflush(stdout)
                return
            }
            let w = NSWindow(
                contentRect: NSRect(x: screen.midX - 180, y: screen.midY - 150, width: 360, height: 300),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .floating
            w.orderFrontRegardless()
            window = w

            for config in BenchConfig.allCases {
                w.contentView = NSHostingView(rootView: BenchView(config: config))
                try? await Task.sleep(for: .seconds(2))   // 描画安定待ち
                FrameCounter.shared.reset()
                let c0 = processCPUSeconds()
                let t0 = CACurrentMediaTime()
                try? await Task.sleep(for: .seconds(sampleSeconds))
                let cpu = (processCPUSeconds() - c0) / (CACurrentMediaTime() - t0) * 100
                results.append((config.rawValue, FrameCounter.shared.fps, cpu))
                print(String(format: "%-10@ fps=%3d  cpu=%5.1f%%",
                             config.rawValue as NSString, FrameCounter.shared.fps, cpu))
                fflush(stdout)
            }

            let base = results.first { $0.0 == "none" }?.2 ?? 0
            print("\n--- 空ウィンドウ(\(String(format: "%.1f", base))%)を引いた純粋な描画コスト ---")
            for (name, fps, cpu) in results where name != "none" {
                let delta = cpu - base
                let verdict = fps >= 55 ? "OK" : "低FPS"
                print(String(format: "%-10@ fps=%3d  +%5.1f%%CPU  %@",
                             name as NSString, fps, delta, verdict as NSString))
            }
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    BenchRunner.shared.run()
}
app.run()
