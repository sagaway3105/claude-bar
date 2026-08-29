import AppKit
import SwiftUI

/// 中身のSwiftUIビューを、レンダーサーバ常駐のCAAnimationでその場漂いさせるホスト。
/// PanelControllerのstartFloating（ウィンドウ全体の漂い）と同じ加算合成方式を
/// ビュー単位に落としたもので、アプリ側の毎フレーム処理はゼロ。
///
/// 3つ表示の球ごとの独立漂いに使う。融合（GlassEffectContainer）を使っていた頃は
/// 球の位置をSwiftUI値で動かす必要があり、どの実装でも7-13%CPUを食った（実測）。
/// 融合をやめたことでこの方式が使えるようになり、独立漂いがタダになった
struct DriftHost<Content: View>: NSViewRepresentable {
    var amplitudeX: CGFloat
    var durationX: TimeInterval
    var amplitudeY: CGFloat
    var durationY: TimeInterval
    /// 開始位相（秒）。球ごとにずらして有機的にする
    var phase: TimeInterval = 0
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> DriftHostView {
        DriftHostView(
            rootView: AnyView(content()),
            amplitudeX: amplitudeX, durationX: durationX,
            amplitudeY: amplitudeY, durationY: durationY,
            phase: phase
        )
    }

    func updateNSView(_ view: DriftHostView, context: Context) {
        view.rootView = AnyView(content())
    }
}

final class DriftHostView: CAAnimationHostView {
    private let amplitudeX: CGFloat
    private let durationX: TimeInterval
    private let amplitudeY: CGFloat
    private let durationY: TimeInterval
    private let phase: TimeInterval

    init(rootView: AnyView,
         amplitudeX: CGFloat, durationX: TimeInterval,
         amplitudeY: CGFloat, durationY: TimeInterval,
         phase: TimeInterval) {
        self.amplitudeX = amplitudeX
        self.durationX = durationX
        self.amplitudeY = amplitudeY
        self.durationY = durationY
        self.phase = phase
        super.init(rootView: rootView)
    }

    override var animationKeys: [String] { ["drift-x", "drift-y"] }

    /// 現在の漂いによる見た目のズレ（AppKit座標・モデル位置は常に原点なので
    /// presentation の位置がそのままズレになる）。当たり判定や破裂の位置合わせに使う
    var driftOffset: CGSize {
        guard let position = hosting.layer?.presentation()?.position else { return .zero }
        return CGSize(width: position.x, height: position.y)
    }

    override func installAnimations(on layer: CALayer) {
        func drift(_ keyPath: String, amplitude: CGFloat, duration: TimeInterval, extraPhase: TimeInterval) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = -amplitude
            animation.toValue = amplitude
            animation.duration = duration
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.isAdditive = true
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // 中間点（オフセット0）から始めて出現時のジャンプを防ぐ
            animation.timeOffset = duration / 2 + extraPhase
            return animation
        }
        layer.add(drift("position.x", amplitude: amplitudeX, duration: durationX, extraPhase: phase), forKey: "drift-x")
        layer.add(drift("position.y", amplitude: amplitudeY, duration: durationY, extraPhase: phase * 0.6), forKey: "drift-y")
    }
}
