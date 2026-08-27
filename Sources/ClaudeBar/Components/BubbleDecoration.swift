import SwiftUI

// ガラス玉（シャボン玉）の装飾。単体バブルと3つ表示で共有する。
// 寸法は基準径72ptを1とするスケールsで一括駆動する。
//
// 設計方針（2026-08-24の全面改訂・リサーチに基づく）:
//  1. 光は「加算」で乗せる。`.fill(.white.opacity())` の不透明な膜は背景の
//     模様を置き換えてしまい、一瞬でシール感が出る。`.screen` / `.plusLighter`
//     を使うと背景の質感が透けたまま明るくなり、塗料ではなく光に見える
//  2. 縁の明るさはフレネル則に従う。反射率は F = F0 + (1-F0)(1-cosθ)^5、
//     水/シャボンの F0 = 0.02。正射影の球では cosθ = √(1-u²)（u=r/R）なので、
//     実効的に「最外周1pt前後だけが急激に明るい」細いランプになる。
//     幅一定のストロークで縁取るのは偽ガラスの典型的な失敗
//  3. ハイライトは形の違う2つで作る。小さく鋭い芯（光源そのもの）と、
//     大きく淡いローブ（空）。同じ弧を太さ違いで2本引いても球には見えない
//  4. 薄膜干渉（虹）は重力で膜厚が変わるため「垂直方向」に色が変わる。
//     角度方向の均一な虹リングは物理的に誤り。さらに干渉は反射成分なので
//     フレネルで縁に寄せる（実物のシャボン玉が縁だけ虹色に見える理由）
//  5. 屈折はしない。シャボン玉は薄い膜で、入射光と射出光が平行になるため
//     背景は歪まない。ガラス球のような集光・全反射は入れない（別物になる）

/// 装飾の濃さ。1.0で標準、下げるほど球が透ける
enum BubbleDecorationStrength {
    static let value: Double = Double(ProcessInfo.processInfo.environment["CLAUDEBAR_DECO"] ?? "100")! / 100
}

/// フレネル反射のプロファイル。最外周だけが急に明るくなる。
/// F0=0.02（水）で F = 0.02 + 0.98(1-√(1-u²))^5 を実測値として離散化したもの
private func fresnelStops(peak: Double) -> [Gradient.Stop] {
    [
        .init(color: .white.opacity(0.02 * peak), location: 0.00),
        .init(color: .white.opacity(0.02 * peak), location: 0.70),
        .init(color: .white.opacity(0.06 * peak), location: 0.85),
        .init(color: .white.opacity(0.14 * peak), location: 0.92),
        .init(color: .white.opacity(0.21 * peak), location: 0.96),
        .init(color: .white.opacity(0.34 * peak), location: 0.98),
        .init(color: .white.opacity(0.48 * peak), location: 0.99),
        .init(color: .white.opacity(1.00 * peak), location: 1.00),
    ]
}

/// 虹（薄膜干渉）を乗せる帯。物理的なフレネルは最外周1pt程度に集中するが、
/// 72ptの球では知覚できないため、干渉が見える帯として意図的に広げている
/// （実物のシャボン玉も縁から内側へかけて虹が滲んで見える）
private func filmBandStops(peak: Double) -> [Gradient.Stop] {
    [
        .init(color: .white.opacity(0), location: 0.00),
        .init(color: .white.opacity(0.04 * peak), location: 0.55),
        .init(color: .white.opacity(0.22 * peak), location: 0.74),
        .init(color: .white.opacity(0.55 * peak), location: 0.86),
        .init(color: .white.opacity(0.90 * peak), location: 0.94),
        .init(color: .white.opacity(1.00 * peak), location: 0.985),
        .init(color: .white.opacity(0.75 * peak), location: 1.00),
    ]
}

/// 薄膜干渉の色。膜厚250→560nm（1オーダー分）を上→下に並べる。
/// 停止位置が上下端で詰まっているのは球の幾何（画面上のyは sinφ に比例）由来で、
/// これが実物のシャボン玉の「上下で縞が詰まる」見え方そのもの
private let filmStops: [Gradient.Stop] = [
    .init(color: Color(red: 0.00, green: 0.62, blue: 0.91), location: 0.000), // 250nm シアン
    .init(color: Color(red: 0.71, green: 0.91, blue: 0.58), location: 0.067), // 302nm 緑
    .init(color: Color(red: 0.98, green: 0.66, blue: 0.26), location: 0.250), // 353nm 橙
    .init(color: Color(red: 0.71, green: 0.04, blue: 0.85), location: 0.500), // 405nm マゼンタ
    .init(color: Color(red: 0.00, green: 0.69, blue: 0.76), location: 0.750), // 457nm ティール
    .init(color: Color(red: 0.52, green: 0.87, blue: 0.27), location: 0.933), // 508nm 緑
    .init(color: Color(red: 0.99, green: 0.60, blue: 0.71), location: 1.000), // 560nm ピンク
]

/// contentの下に敷く層: 球全体の拡散照明（加算）
struct BubbleDepthUnderlay: View {
    /// 基準72ptに対するスケール
    var s: CGFloat

    var body: some View {
        // 空からの広い淡い照明。加算なので背景の模様は残ったまま明るくなる
        Circle()
            .fill(RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .white.opacity(0.14), location: 0),
                    .init(color: .white.opacity(0.07), location: 0.55),
                    .init(color: .white.opacity(0.02), location: 0.85),
                    .init(color: .clear, location: 1),
                ]),
                center: UnitPoint(x: 0.33, y: 0.28),
                startRadius: 0, endRadius: 46 * s
            ))
            .blendMode(.screen)
            .opacity(BubbleDecorationStrength.value)
    }
}

/// contentの上に重ねる層: フレネル縁 + 薄膜干渉 + 2ローブのスペキュラ
struct BubbleGlossOverlay: View {
    /// 基準72ptに対するスケール
    var s: CGFloat

    var body: some View {
        ZStack {
            // ── 薄膜干渉（虹）: 垂直方向の色変化をフレネルでマスクして縁に寄せる
            Circle()
                .fill(LinearGradient(stops: filmStops, startPoint: .top, endPoint: .bottom))
                .mask(Circle().fill(RadialGradient(
                    gradient: Gradient(stops: filmBandStops(peak: 1.0)),
                    center: .center, startRadius: 0, endRadius: 36 * s
                )))
                .blendMode(.screen)
                .opacity(1.0)

            // ── フレネル縁: 最外周だけが鋭く光る。方位で明暗を付けて
            //    「上が明るく側面が落ちる」自然な光の回り方にする
            Circle()
                .fill(RadialGradient(
                    gradient: Gradient(stops: fresnelStops(peak: 0.85)),
                    center: .center, startRadius: 0, endRadius: 36 * s
                ))
                .mask(Circle().fill(AngularGradient(stops: [
                    .init(color: .white.opacity(0.35), location: 0),     // 右
                    .init(color: .white.opacity(0.75), location: 0.25),  // 下
                    .init(color: .white.opacity(0.35), location: 0.5),   // 左
                    .init(color: .white, location: 0.75),                // 上
                    .init(color: .white.opacity(0.35), location: 1),
                ], center: .center)))
                .blendMode(.screen)

            // ── 左上のグロス: 球面に沿って湾曲し、両端がすっと消える光の筋。
            //    暈（広く柔らかい）と芯（細く鋭い）の2層とも、弧に沿った
            //    グラデーションで中央が最も明るくなる。直線のカプセルや
            //    白丸だと「貼った感」が出るため、必ず弧で描く
            Circle()
                .trim(from: 0.51, to: 0.77)
                .stroke(
                    AngularGradient(stops: [
                        .init(color: .clear, location: 0.51),
                        .init(color: .white.opacity(0.42), location: 0.64),
                        .init(color: .clear, location: 0.77),
                    ], center: .center),
                    style: StrokeStyle(lineWidth: 6 * s, lineCap: .round)
                )
                .padding(5 * s)
                .blur(radius: 2.2 * s)
                .blendMode(.screen)
            Circle()
                .trim(from: 0.535, to: 0.745)
                .stroke(
                    AngularGradient(stops: [
                        .init(color: .clear, location: 0.535),
                        .init(color: .white.opacity(0.95), location: 0.64),
                        .init(color: .clear, location: 0.745),
                    ], center: .center),
                    style: StrokeStyle(lineWidth: 2.6 * s, lineCap: .round)
                )
                .padding(6 * s)
                .blur(radius: 0.4 * s)
                .blendMode(.plusLighter)

            // ── 裏面反射: 球の内側（凹面鏡）に映る、反転した薄い光源像。
            //    前面反射の対角に、暗く小さく出る（実物のガラス球の特徴）
            Circle()
                .fill(RadialGradient(
                    colors: [.white.opacity(0.30), .clear],
                    center: .center, startRadius: 0, endRadius: 4 * s
                ))
                .frame(width: 8 * s, height: 8 * s)
                .position(x: 47 * s, y: 49 * s)
                .blur(radius: 1.6 * s)
                .blendMode(.screen)
        }
        .frame(width: 72 * s, height: 72 * s)
        .opacity(BubbleDecorationStrength.value)
    }
}
