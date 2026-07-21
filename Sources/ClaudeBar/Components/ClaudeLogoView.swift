import SwiftUI

extension Color {
    /// Claudeブランドのテラコッタオレンジ (#D97757)
    static let claudeOrange = Color(red: 0.851, green: 0.467, blue: 0.341)
}

/// Claudeのサンバーストロゴ風シェイプ。
/// トークン消費中は回転しながら脈打つ。
struct ClaudeLogoView: View {
    var animating: Bool
    var color: Color = .primary

    var body: some View {
        Group {
            if animating {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    StarburstShape()
                        .fill(color)
                        .rotationEffect(.radians(t * 1.4))
                        .scaleEffect(1 + 0.09 * sin(t * 5))
                }
            } else {
                StarburstShape().fill(color)
            }
        }
    }
}

/// 長さの不揃いな光条が放射状に伸びるサンバースト
struct StarburstShape: Shape {
    var rays = 9

    func path(in rect: CGRect) -> Path {
        let lengths: [CGFloat] = [1.0, 0.78, 0.93, 0.84, 1.0, 0.8, 0.95, 0.82, 0.9]
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let innerRadius = radius * 0.13
        let baseHalfAngle = CGFloat.pi / CGFloat(rays) * 0.6
        let tipHalfAngle = baseHalfAngle * 0.42

        for i in 0..<rays {
            let angle = CGFloat(i) / CGFloat(rays) * 2 * .pi - .pi / 2
            let length = radius * lengths[i % lengths.count]
            path.move(to: point(center, innerRadius, angle - baseHalfAngle))
            path.addLine(to: point(center, length, angle - tipHalfAngle))
            path.addLine(to: point(center, length, angle + tipHalfAngle))
            path.addLine(to: point(center, innerRadius, angle + baseHalfAngle))
            path.closeSubpath()
        }
        let dotRadius = innerRadius * 1.35
        path.addEllipse(in: CGRect(
            x: center.x - dotRadius, y: center.y - dotRadius,
            width: dotRadius * 2, height: dotRadius * 2
        ))
        return path
    }

    private func point(_ center: CGPoint, _ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
}
