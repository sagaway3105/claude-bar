import AppKit
import SwiftUI

extension Color {
    /// Claudeブランドのテラコッタオレンジ (#D97757)
    static let claudeOrange = Color(red: 0.851, green: 0.467, blue: 0.341)
}

/// Claude公式のスパーク（アスタリスク）風ロゴ。
/// トークン消費中は回転しながら脈打つ。
///
/// 回転・脈動はレンダーサーバ側のCAAnimation（SpinningLogoView）で行い、
/// アプリのCPUを使わない。以前のTimelineViewによる毎フレーム再計算は、
/// バブル内ではLiquid Glassの上での再合成を毎フレーム誘発して重かった
/// （消費中CPU約25%の主因。レイヤー回転化で漂いぶんの約8%まで下がる）
struct ClaudeLogoView: View {
    var animating: Bool
    var color: Color = .primary

    var body: some View {
        if animating {
            SpinningLogoLayer(color: color)
        } else {
            logo
        }
    }

    private var logo: some View {
        StarburstShape().fill(color)
    }
}

/// 回転中のロゴ。形状を一度だけ画像化してレイヤーに載せ、
/// 回転（1.4rad/s）と脈動（±9%）をCAAnimationで無限リピートする
private struct SpinningLogoLayer: NSViewRepresentable {
    var color: Color

    func makeNSView(context: Context) -> SpinningLogoView { SpinningLogoView() }

    func updateNSView(_ view: SpinningLogoView, context: Context) {
        view.logoColor = NSColor(color)
    }
}

final class SpinningLogoView: NSView {
    var logoColor: NSColor = .labelColor {
        didSet { if oldValue != logoColor { renderContents() } }
    }
    /// 回転はバッキングレイヤーではなくこのサブレイヤーで行う。
    /// バッキングレイヤーのanchorPoint/positionはAppKitが管理していて、
    /// 直接いじるとレイアウトのたびに取り戻されて回転軸がズレる（ロゴが公転してしまう）
    private let spinLayer = CALayer()
    private var lastSize = CGSize.zero
    private var occlusionObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        spinLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(spinLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.size != lastSize else { return }
        lastSize = bounds.size
        // サブレイヤーの親座標系はビューのboundsなので、中央アンカー+中央配置で自転になる
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        spinLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        spinLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        renderContents()
        installAnimationsIfNeeded()
    }

    /// ウィンドウが隠れるとレンダーサーバがアニメーションを破棄するため、
    /// 再表示（オクルージョン変化）のたびに張り直す（バブルの漂いと同じ問題への対策）
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            // 破棄後もモデルレイヤーには死んだアニメーションが残り in-needed ガードを
            // すり抜けるため、可視化時は一度外してから張り直す（位相リセットは許容）
            MainActor.assumeIsolated {
                guard let self, self.window?.occlusionState.contains(.visible) == true else { return }
                self.spinLayer.removeAnimation(forKey: "spin")
                self.spinLayer.removeAnimation(forKey: "pulse")
                self.installAnimationsIfNeeded()
            }
        }
        installAnimationsIfNeeded()
    }

    private func renderContents() {
        guard bounds.width > 0 else { return }
        spinLayer.contents = Self.rasterizedLogo(color: logoColor, size: bounds.size.width)
    }

    private func installAnimationsIfNeeded() {
        let layer = spinLayer
        guard layer.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi // SwiftUI版（時計回り）と同じ向き
        spin.duration = 2 * .pi / 1.4 // 角速度1.4rad/s（SwiftUI版と同じ）
        spin.repeatCount = .infinity
        layer.add(spin, forKey: "spin")

        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.91
        pulse.toValue = 1.09
        pulse.duration = .pi / 5 // sin(t*5)の半周期（SwiftUI版と同じリズム）
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "pulse")
    }

    /// StarburstShapeを3倍解像度でラスタライズする（15pt程度の表示ではベクターと区別がつかない）
    private static func rasterizedLogo(color: NSColor, size: CGFloat) -> CGImage? {
        let scale: CGFloat = 3
        let pixels = max(1, Int(size * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: pixels, height: pixels,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // SwiftUI座標（上原点）で定義された形状をCG（下原点）へ反転して描く
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: 1, y: -1)
        let path = StarburstShape().path(in: CGRect(x: 0, y: 0, width: size, height: size))
        ctx.addPath(path.cgPath)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        return ctx.makeImage()
    }
}

/// 丸端・長さ不揃いのスポークが放射するスパーク形状（Claude公式ロゴ準拠の雰囲気）
struct StarburstShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        // 長い光条と短い光条が交互に近いリズムで並ぶ
        let lengths: [CGFloat] = [1.0, 0.68, 0.88, 0.74, 1.0, 0.66, 0.90, 0.72, 0.97, 0.68, 0.86, 0.74]
        let angleJitter: [CGFloat] = [0, 0.05, -0.04, 0.03, 0, -0.05, 0.04, 0, -0.03, 0.05, -0.04, 0.03]
        let count = lengths.count
        let rayWidth = radius * 0.15
        let innerRadius: CGFloat = 0 // 中心まで重ねて穴を作らない

        var path = Path()
        for i in 0..<count {
            let angle = CGFloat(i) / CGFloat(count) * 2 * .pi - .pi / 2 + angleJitter[i]
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)
            let rayRect = CGRect(
                x: innerRadius, y: -rayWidth / 2,
                width: radius * lengths[i] - innerRadius, height: rayWidth
            )
            path.addRoundedRect(
                in: rayRect,
                cornerSize: CGSize(width: rayWidth / 2, height: rayWidth / 2),
                transform: transform
            )
        }
        return path
    }
}
