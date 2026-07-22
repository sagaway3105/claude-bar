import SwiftUI

extension Color {
    /// Claudeブランドのテラコッタオレンジ (#D97757)
    static let claudeOrange = Color(red: 0.851, green: 0.467, blue: 0.341)
}

/// Claude公式のスパーク（アスタリスク）風ロゴ。
/// トークン消費中は回転しながら脈打つ。outlinedで縁取り（背景に埋もれない）。
struct ClaudeLogoView: View {
    var animating: Bool
    var color: Color = .primary
    var outlined: Bool = false

    var body: some View {
        if animating {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                logo
                    .rotationEffect(.radians(t * 1.4))
                    .scaleEffect(1 + 0.09 * sin(t * 5))
            }
        } else {
            logo
        }
    }

    private var logo: some View {
        ZStack {
            if outlined {
                // 下層に太めのストロークを敷いて縁取りにする（メニューバーの明暗に自動追従）
                StarburstShape()
                    .stroke(Color.primary.opacity(0.55), lineWidth: 1.8)
            }
            StarburstShape().fill(color)
        }
    }
}

/// 丸端・長さ不揃いのスポークが放射するスパーク形状（Claude公式ロゴ準拠の雰囲気）
struct StarburstShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        // 長い光条と短い光条が交互に近いリズムで並ぶ
        let lengths: [CGFloat] = [1.0, 0.72, 0.93, 0.70, 1.0, 0.72, 0.93, 0.70, 1.0, 0.72]
        let angleJitter: [CGFloat] = [0, 0.04, -0.03, 0.04, 0, -0.04, 0.03, 0, -0.03, 0.04]
        let count = lengths.count
        let rayWidth = radius * 0.18
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
