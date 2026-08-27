import AppKit
import SwiftUI

/// 中身のSwiftUIビューを±数度でゆっくり揺らすホスト。
///
/// 揺れはCAKeyframeAnimation（sin波形・無限リピート）としてレンダーサーバに
/// 常駐させ、アプリ側の毎フレーム処理をなくす。以前のTimelineView(30fps)による
/// body再評価は待機中バブルCPU約7%の主因だった。宣言的repeatForeverへの置換も
/// 試したが、レンダーサーバに委譲されず毎フレーム刻むためむしろ悪化（約9%）。
struct WobbleHost<Content: View>: NSViewRepresentable {
    /// 振れ幅（度）。旧実装 sin(t*0.9)*3 と同じ既定値
    var amplitudeDegrees: Double = 3
    /// 周期（秒）。旧実装の角速度0.9rad/s → 2π/0.9 ≈ 7.0秒
    var period: TimeInterval = 2 * .pi / 0.9
    /// 開始位相（周期に対する割合0-1）。3つ表示で球ごとにずらし、
    /// 同期して「全部同じ動き」に見えるのを防ぐ
    var phase: Double = 0
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> WobbleHostView {
        WobbleHostView(
            rootView: AnyView(content()),
            amplitude: amplitudeDegrees * .pi / 180,
            period: period,
            phase: phase
        )
    }

    func updateNSView(_ view: WobbleHostView, context: Context) {
        view.rootView = AnyView(content())
    }
}

final class WobbleHostView: CAAnimationHostView {
    private let amplitude: CGFloat
    private let period: TimeInterval
    private let phase: Double
    private var lastSize = CGSize.zero
    /// 初回インストール時刻（レイヤー時間）。リサイズやオクルージョンでの
    /// 張り直し時もこれをbeginTimeに使い、揺れの位相を連続させる
    /// （以前は張り直しごとに位相が固定リセットされ、膨張アニメ中に揺れが凍っていた）
    private var timeAnchor: CFTimeInterval?

    init(rootView: AnyView, amplitude: CGFloat, period: TimeInterval, phase: Double = 0) {
        self.amplitude = amplitude
        self.period = period
        self.phase = phase
        super.init(rootView: rootView)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.size != lastSize else { return }
        lastSize = bounds.size
        // 回転の中心補正はサイズ依存なので、サイズが変わったら張り直す
        reinstallAnimations()
    }

    override var animationKeys: [String] { ["wobble"] }

    /// sin(t)と同位相のゆらぎ: 0 → +A → 0 → -A → 0 をeaseで繋ぐ。
    /// AppKit管理のバッキングレイヤーはanchorPointが(0,0)のため、
    /// 中心回転は「中心へ平行移動→回転→戻す」を焼き込んだtransformで行う
    /// （anchorPointの直接変更はレイアウトのたびに取り戻される）
    override func installAnimations(on layer: CALayer) {
        guard bounds.width > 0 else { return }

        func rotated(_ angle: CGFloat) -> CATransform3D {
            let cx = bounds.midX, cy = bounds.midY
            var t = CATransform3DMakeTranslation(cx, cy, 0)
            t = CATransform3DRotate(t, angle, 0, 0, 1)
            return CATransform3DTranslate(t, -cx, -cy, 0)
        }

        let wobble = CAKeyframeAnimation(keyPath: "transform")
        wobble.values = [rotated(0), rotated(amplitude), rotated(0), rotated(-amplitude), rotated(0)]
        wobble.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        wobble.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),  // 0 → 山: 頂点へ減速
            CAMediaTimingFunction(name: .easeIn),   // 山 → 0: 頂点から加速
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeIn),
        ]
        wobble.duration = period
        wobble.repeatCount = .infinity
        if timeAnchor == nil {
            timeAnchor = layer.convertTime(CACurrentMediaTime(), from: nil)
        }
        wobble.beginTime = timeAnchor ?? 0
        wobble.timeOffset = phase * period
        layer.add(wobble, forKey: "wobble")
    }
}
