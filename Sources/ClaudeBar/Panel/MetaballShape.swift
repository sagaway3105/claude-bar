import SwiftUI

/// メタボールを構成する1つの球
struct Metaball: Equatable {
    var center: CGPoint
    var radius: CGFloat
}

/// 複数の球を「表面張力でくっついた」ように繋ぐシルエット。
///
/// 近い2球のあいだに解析的なくびれ（ネック）を張る古典的メタボール手法。
/// 縁の距離が縮むほどネックが太くなり、重なると円の合併輪郭に漸近する。
/// ガラス・虹色リム・下地ヘイズの3役で同じ形状を使い回すため、
/// macOS 26のLiquid Glassでも旧OSのすりガラスでも見た目が揃う。
struct MetaballShape: Shape {
    var balls: [Metaball]
    /// ネックのハンドル長。大きいほど張りが強い（2.0〜3.0が自然）
    var handleLenRate: CGFloat = 2.4
    /// 縁の距離がこれ以下になったらネックを張り始める
    var maxNeckGap: CGFloat = 26
    /// ネックの広がり（0.4〜0.6が自然）
    var spread: CGFloat = 0.5

    /// アニメーション中も滑らかに補間させる（球の座標と半径を連続値として扱う）
    var animatableData: AnimatableVector {
        get { AnimatableVector(balls.flatMap { [$0.center.x, $0.center.y, $0.radius] }) }
        set {
            let values = newValue.values
            guard values.count == balls.count * 3 else { return }
            for i in balls.indices {
                balls[i].center = CGPoint(x: values[i * 3], y: values[i * 3 + 1])
                balls[i].radius = values[i * 3 + 2]
            }
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for ball in balls where ball.radius > 0 {
            path.addEllipse(in: CGRect(
                x: ball.center.x - ball.radius, y: ball.center.y - ball.radius,
                width: ball.radius * 2, height: ball.radius * 2
            ))
        }
        // 各ペアのネック。塗りはnonZeroなので重ねるだけで合併シルエットになる
        for i in balls.indices {
            for j in balls.indices where j > i {
                if let neck = Self.neck(
                    balls[i], balls[j],
                    handleLenRate: handleLenRate, maxNeckGap: maxNeckGap, spread: spread
                ) {
                    path.addPath(neck)
                }
            }
        }
        return path
    }

    /// 輪郭線（虹色リム）用に内部の線が出ない単一シルエットを作る。
    /// booleanのunionは塗りより高コストなので、必要な箇所だけで使う
    func outlinePath(in rect: CGRect) -> Path {
        var shapes: [Path] = balls.filter { $0.radius > 0 }.map { ball in
            Path(ellipseIn: CGRect(
                x: ball.center.x - ball.radius, y: ball.center.y - ball.radius,
                width: ball.radius * 2, height: ball.radius * 2
            ))
        }
        for i in balls.indices {
            for j in balls.indices where j > i {
                if let neck = Self.neck(
                    balls[i], balls[j],
                    handleLenRate: handleLenRate, maxNeckGap: maxNeckGap, spread: spread
                ) {
                    shapes.append(neck)
                }
            }
        }
        guard var union = shapes.first else { return Path() }
        for shape in shapes.dropFirst() { union = union.union(shape) }
        return union
    }

    /// 2球のあいだのくびれ。繋がる条件を満たさなければnil
    static func neck(
        _ a: Metaball, _ b: Metaball,
        handleLenRate: CGFloat, maxNeckGap: CGFloat, spread: CGFloat
    ) -> Path? {
        let r1 = a.radius, r2 = b.radius
        guard r1 > 0, r2 > 0 else { return nil }
        let dx = b.center.x - a.center.x
        let dy = b.center.y - a.center.y
        let d = sqrt(dx * dx + dy * dy)
        // 離れすぎ / 片方がもう片方を完全に含む場合は繋がない
        guard d > 0, d <= r1 + r2 + maxNeckGap, d > abs(r1 - r2) else { return nil }

        let halfPi = CGFloat.pi / 2
        var u1: CGFloat = 0
        var u2: CGFloat = 0
        if d < r1 + r2 { // 重なっている: 交点の角度ぶんネックの付け根を外へずらす
            u1 = acos(clamp((r1 * r1 + d * d - r2 * r2) / (2 * r1 * d)))
            u2 = acos(clamp((r2 * r2 + d * d - r1 * r1) / (2 * r2 * d)))
        }
        let centerAngle = atan2(dy, dx)
        let maxSpread = acos(clamp((r1 - r2) / d))

        let angle1 = centerAngle + u1 + (maxSpread - u1) * spread
        let angle2 = centerAngle - u1 - (maxSpread - u1) * spread
        let angle3 = centerAngle + .pi - u2 - (.pi - u2 - maxSpread) * spread
        let angle4 = centerAngle - .pi + u2 + (.pi - u2 - maxSpread) * spread

        let p1 = point(a.center, angle1, r1)
        let p2 = point(a.center, angle2, r1)
        let p3 = point(b.center, angle3, r2)
        let p4 = point(b.center, angle4, r2)

        // ハンドル長: 離れるほど細く（張力が弱まって切れる直前の形）
        let totalRadius = r1 + r2
        let base = min(spread * handleLenRate, distance(p1, p3) / totalRadius)
        let scale = base * min(1, d * 2 / totalRadius)
        let h1len = r1 * scale
        let h2len = r2 * scale

        var path = Path()
        path.move(to: p1)
        path.addCurve(
            to: p3,
            control1: point(p1, angle1 - halfPi, h1len),
            control2: point(p3, angle3 + halfPi, h2len)
        )
        path.addLine(to: p4)
        path.addCurve(
            to: p2,
            control1: point(p4, angle4 - halfPi, h2len),
            control2: point(p2, angle2 + halfPi, h1len)
        )
        path.closeSubpath()
        return path
    }

    private static func point(_ origin: CGPoint, _ angle: CGFloat, _ length: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        sqrt(pow(b.x - a.x, 2) + pow(b.y - a.y, 2))
    }

    /// acosの定義域外に丸め誤差で出てNaNになるのを防ぐ
    private static func clamp(_ v: CGFloat) -> CGFloat { min(1, max(-1, v)) }
}

/// Shapeのアニメーション用に可変長の値を運ぶベクトル
struct AnimatableVector: VectorArithmetic {
    var values: [CGFloat]

    init(_ values: [CGFloat] = []) { self.values = values }

    static var zero: AnimatableVector { AnimatableVector() }

    static func + (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        AnimatableVector(zip(lhs.values, rhs.values).map(+))
    }

    static func - (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
        AnimatableVector(zip(lhs.values, rhs.values).map(-))
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * CGFloat(rhs) }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + Double($1 * $1) }
    }
}
