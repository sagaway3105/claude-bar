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
    static let value: Double = envPercent("CLAUDEBAR_DECO", default: 100)
}

/// 虹（薄膜干渉）の濃さ。1.0で従来どおり、下げるほど帯が控えめになる。
/// 検証用: CLAUDEBAR_RAINBOW=0-100（既定90＝「ほんの少し抑えた」状態）
enum BubbleRainbowStrength {
    static let value: Double = {
        let raw = Double(ProcessInfo.processInfo.environment["CLAUDEBAR_RAINBOW"] ?? "90") ?? 90
        return min(max(raw, 0), 100) / 100
    }()
}

/// 虹の減算側（multiply）の濃さ。加算（screen）の虹は白背景では原理的に見えないため、
/// 明るい背景用に「透過光から補色を抜く」層を足す。検証用: CLAUDEBAR_RAINBOW_SUB=0-100
enum BubbleRainbowSubtractive {
    static let value: Double = {
        let raw = Double(ProcessInfo.processInfo.environment["CLAUDEBAR_RAINBOW_SUB"] ?? "35") ?? 35
        return min(max(raw, 0), 100) / 100
    }()
}

/// 立体感の陰（減算）の強さ。加算の光だけでは**明るい外観で球が平らに見える**ため、
/// 縁の減光（limb darkening）と右下の陰を入れる。ダークではガラス自体が暗く
/// コントラストが足りているので弱める。検証用: CLAUDEBAR_SHADING=0-200
enum BubbleShadingStrength {
    static let value: Double = {
        let raw = Double(ProcessInfo.processInfo.environment["CLAUDEBAR_SHADING"] ?? "100") ?? 100
        return min(max(raw, 0), 200) / 100
    }()
    /// 外観ごとの倍率。ライトを主役にする
    static func scaled(for scheme: ColorScheme) -> Double {
        value * (scheme == .dark ? 0.35 : 1.0)
    }
}

/// ガラスの局所クリア化の強さ（0=クリア化しない＝Liquid Glassを全面にそのまま残す、
/// 1.0=2026-08-27の「有機的な局所透明化」）。検証用: CLAUDEBAR_CLARITY=0-100
///
/// 局所クリア化は「透明にする」のではなく**ガラスを削る**操作なので、削った場所は
/// ぼかし・明度適応・縁レンズごと消えて生のデスクトップになる（＝Liquid Glassが無くなる）。
/// ガラスの質感を優先するため既定は 0（マスク自体を外す）
enum BubbleClarity {
    static let value: Double = {
        let raw = Double(ProcessInfo.processInfo.environment["CLAUDEBAR_CLARITY"] ?? "0") ?? 0
        return min(max(raw, 0), 100) / 100
    }()
    /// 完全にオフ。マスク（ぼかし楕円7枚＋drawingGroup）ごと外せる
    static var isOff: Bool { value <= 0.001 }
}

extension View {
    /// ガラスの局所クリア化を掛ける。オフのときはマスクを付けない
    /// （ぼかしツリーと drawingGroup の合成コストも消える）
    func bubbleClarity(ringFraction: Double = 0) -> some View {
        modifier(BubbleClarityModifier(ringFraction: ringFraction))
    }
}

struct BubbleClarityModifier: ViewModifier {
    var ringFraction: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if BubbleClarity.isOff {
            content
        } else {
            content.mask(BubbleClarityMask(ringFraction: ringFraction))
        }
    }
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
    // 2026-08-27: 一度は帯を内側へ広げたが「9.9.9（拡大前）の見た目が好み」との
    // 判断で拡大前の分布へ戻した。さらに「ほんの少し抑える」ぶんは
    // BubbleRainbowStrength（既定0.9）で peak 側から掛ける
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

/// ガラスの局所クリア化マスク（alpha=ガラスの残存率）。
/// 磨りのコアを「重なり合う複数のぼけた楕円＝雲」で作り、境界が真円に
/// ならないようにする（綺麗な同心円はシールっぽく見えるという指摘への対応）。
/// クリアパッチが外周寄りをさらに素通しにし、実物の膜ムラのような表情を出す。
/// 3つ表示ではこのマスクがリングにも掛かるため、実際に描かれている弧の
/// 真下だけを ringFraction で保護する（円環全体を保護すると円形の痕跡が残る）
struct BubbleClarityMask: View {
    /// 使用量リングの進捗（0-1）。弧の下だけ磨りを復元する。単体バブルは
    /// リングがマスクの外にあるので 0 のままでよい
    var ringFraction: Double = 0

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                // ごく薄い全体のベール（完全な素通しは球として消えるため）。
                // あくまでシャボン玉: 透明が主役で、磨りは膜のムラ程度に留める
                Color.white.opacity(0.18)
                // 磨りの雲: 大きさ・角度・中心をずらした楕円の重なり。
                // 文字コラム（中央の縦帯）は複数枚が必ず覆う配置にする
                frostCloud(w: 0.50, h: 0.62, x: 0.50, y: 0.47, angle: 8, opacity: 0.95, d: d)
                frostCloud(w: 0.42, h: 0.30, x: 0.42, y: 0.62, angle: -16, opacity: 0.78, d: d)
                frostCloud(w: 0.36, h: 0.26, x: 0.62, y: 0.41, angle: 24, opacity: 0.70, d: d)
                frostCloud(w: 0.28, h: 0.20, x: 0.46, y: 0.29, angle: -8, opacity: 0.64, d: d)
                // クリアパッチ: 外周寄りのアルファを削って「ところどころ素通し」に
                clearPatch(w: 0.40, h: 0.24, x: 0.24, y: 0.70, angle: -22, strength: 0.90, d: d)
                clearPatch(w: 0.34, h: 0.22, x: 0.80, y: 0.36, angle: 30, strength: 0.85, d: d)
                clearPatch(w: 0.28, h: 0.18, x: 0.74, y: 0.76, angle: -38, strength: 0.78, d: d)
                // 縁の帯: 薄膜・フレネルの土台。最外周の円形は縁の光と同化するので許容
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.84),
                            .init(color: .white.opacity(0.75), location: 0.92),
                            .init(color: .white.opacity(0.85), location: 1.0),
                        ]),
                        center: .center, startRadius: 0, endRadius: d / 2
                    ))
                // ガラスの下限: クリア化の強さを下げるほど、削った場所へ
                // ガラスを戻す（source-over なのでアルファの床として効く）。
                // destinationOut のパッチより前面に置くことが必須
                if BubbleClarity.value < 1 {
                    Color.white.opacity(1 - BubbleClarity.value)
                }
                // リング保護（3つ表示用）: 描かれている弧の真下だけ磨りを復元。
                // 弧の外には何も描かないので円形の痕跡は出ない
                if ringFraction > 0 {
                    Circle()
                        .trim(from: 0, to: max(0.003, ringFraction))
                        .stroke(.white, style: StrokeStyle(lineWidth: 0.10 * d, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(0.093 * d)
                }
            }
            // マスクは静的な形なので1枚のテクスチャに焼く。ライブのblurツリーの
            // ままだと、ガラスの再描画（漂いで背景が毎フレーム変わる）のたびに
            // 7枚のぼかし楕円を再合成してGPUを食う（実測で単体0.62→焼き後は下記参照）
            .drawingGroup()
        }
    }

    /// 磨りの雲1枚（白を足す）
    private func frostCloud(w: CGFloat, h: CGFloat, x: CGFloat, y: CGFloat,
                            angle: Double, opacity: Double, d: CGFloat) -> some View {
        Ellipse()
            .fill(Color.white.opacity(opacity))
            .frame(width: w * d, height: h * d)
            .rotationEffect(.degrees(angle))
            .blur(radius: 0.06 * d)
            .position(x: x * d, y: y * d)
    }

    /// クリアパッチ1枚。destinationOutでアルファを削る（strength=素通し度）
    private func clearPatch(w: CGFloat, h: CGFloat, x: CGFloat, y: CGFloat,
                            angle: Double, strength: Double, d: CGFloat) -> some View {
        Ellipse()
            .fill(Color.white.opacity(strength))
            .frame(width: w * d, height: h * d)
            .rotationEffect(.degrees(angle))
            .blur(radius: 0.07 * d)
            .position(x: x * d, y: y * d)
            .blendMode(.destinationOut)
    }
}

/// 薄膜干渉の色（膜厚250→560nm、1オーダー分）の素の値。
/// 停止位置が上下端で詰まっているのは球の幾何（画面上のyは sinφ に比例）由来で、
/// これが実物のシャボン玉の「上下で縞が詰まる」見え方そのもの
private let filmBaseColors: [(r: Double, g: Double, b: Double, at: Double)] = [
    (0.00, 0.62, 0.91, 0.000), // 250nm シアン
    (0.71, 0.91, 0.58, 0.067), // 302nm 緑
    (0.98, 0.66, 0.26, 0.250), // 353nm 橙
    (0.71, 0.04, 0.85, 0.500), // 405nm マゼンタ
    (0.00, 0.69, 0.76, 0.750), // 457nm ティール
    (0.52, 0.87, 0.27, 0.933), // 508nm 緑
    (0.99, 0.60, 0.71, 1.000), // 560nm ピンク
]

/// 虹の彩度。1.0で素の干渉色、下げるほど同じ明るさのまま色味だけ薄くなる
/// （輝度を保って灰色へ寄せる＝加算側の明るさ・減算側の暗さは変えない）。
/// 検証用: CLAUDEBAR_RAINBOW_SAT=0-100
enum BubbleRainbowSaturation {
    static let value: Double = {
        let raw = Double(ProcessInfo.processInfo.environment["CLAUDEBAR_RAINBOW_SAT"] ?? "85") ?? 85
        return min(max(raw, 0), 100) / 100
    }()
}

/// 彩度を落とした薄膜干渉の色。輝度（Rec.709）を軸に灰色へ寄せる
private let filmStops: [Gradient.Stop] = filmBaseColors.map { c in
    let s = BubbleRainbowSaturation.value
    let y = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    return Gradient.Stop(
        color: Color(red: y + (c.r - y) * s, green: y + (c.g - y) * s, blue: y + (c.b - y) * s),
        location: c.at
    )
}

/// 落ち影の倍率（1.0で標準）。既存の装飾は全て加算合成（screen/plusLighter）のため
/// 白背景では原理的に見えず、球が消える。落ち影だけは「暗くする」要素なので
/// 通常合成で描く。**ライト/ダークどちらでも付ける**（2026-08-27ユーザー指定）。
/// 検証用: CLAUDEBAR_SHADOW=0-300（%・0で無効）
enum BubbleShadowStrength {
    static let value: Double = {
        let raw = Double(ProcessInfo.processInfo.environment["CLAUDEBAR_SHADOW"] ?? "100") ?? 100
        return min(max(raw, 0), 300) / 100
    }()
    static var isOn: Bool { value > 0.001 }

    /// ぼかし半径の倍率。広げるほど「軽い」影になる（同じ濃さでも重く見えない）。
    /// 検証用: CLAUDEBAR_SHADOW_BLUR=50-400（%）
    static let blur: Double = {
        let raw = Double(ProcessInfo.processInfo.environment["CLAUDEBAR_SHADOW_BLUR"] ?? "100") ?? 100
        return min(max(raw, 25), 400) / 100
    }()
}

/// 白背景での視認性検証用（暫定A/B）: CLAUDEBAR_EDGE=hairline|limb
enum BubbleEdgeVariant {
    static let value = ProcessInfo.processInfo.environment["CLAUDEBAR_EDGE"] ?? "off"
    static var hairline: Bool { value == "hairline" || value == "combo" }
    static var limb: Bool { value == "limb" }
}

/// contentの下に敷く層: 落ち影（通常合成）＋球全体の拡散照明（加算）
struct BubbleDepthUnderlay: View {
    /// 基準72ptに対するスケール
    var s: CGFloat

    /// 影から本体シルエットをくり抜く型。影が球の中へ回り込むと
    /// 「黒いブラー」になって一気に安っぽくなる
    static func silhouetteKnockout(s: CGFloat) -> some View {
        Rectangle()
            .padding(-60 * s)
            .overlay(Circle().blendMode(.destinationOut))
            .compositingGroup()
    }

    var body: some View {
        // 白背景で球が消えないための落ち影。2層に分けるのは実物の影と同じ理由で、
        // 広く淡い環境光の影が「浮いている」感を、狭く濃いキーライトの影が輪郭を作る。
        // 1層だけだと「濃くすると汚い／薄くすると見えない」の両立ができない。
        // 光源は左上（グロスの位置）なので影は右下へ流す。
        // 本体シルエットをくり抜くので球の中は暗くならない（黒いブラーは却下済み）
        if BubbleShadowStrength.isOn {
            // 環境光の影: 非常に広く淡い。半径を大きく取るほど同じ濃さでも軽く見える
            Circle()
                .fill(Color.black.opacity(0.09 * BubbleShadowStrength.value))
                .blur(radius: 22 * s * BubbleShadowStrength.blur)
                .offset(y: 2 * s)
                .mask { Self.silhouetteKnockout(s: s) }
            // キーライトの影: 相対的に狭いが、これも十分ぼかす
            Circle()
                .fill(Color.black.opacity(0.21 * BubbleShadowStrength.value))
                .blur(radius: 11 * s * BubbleShadowStrength.blur)
                .offset(x: 1.5 * s, y: 5 * s)
                .mask { Self.silhouetteKnockout(s: s) }
        }
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
        // 文字コラムの白パッド: 局所クリア化でガラスを削ったときに、文字の背後だけ
        // 磨りを取り戻すための補償。クリア化オフ（＝ガラスが全面にある）では
        // 白く曇るだけなので出さない
        if !BubbleClarity.isOff {
            Ellipse()
                .fill(RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: .white.opacity(0.13), location: 0),
                        .init(color: .white.opacity(0.08), location: 0.6),
                        .init(color: .clear, location: 1),
                    ]),
                    center: .center, startRadius: 0, endRadius: 24 * s
                ))
                .frame(width: 44 * s, height: 58 * s)
                .position(x: 36 * s, y: 36 * s)
                .blendMode(.screen)
                .opacity(BubbleDecorationStrength.value)
        }
    }
}

/// contentの上・光沢の下に敷く層: 立体感の陰（減算合成）。
///
/// 装飾はすべて加算（screen/plusLighter）なので、ガラスが明るく描かれる
/// ライト外観では「光を足しても白に埋もれて平らに見える」。球に見せるには
/// **暗くする側**が要る。黒ではなく寒色グレーを multiply で薄く乗せると、
/// 濁らずにガラスの厚みとして読める（黒いブラーは過去に却下済み）。
///  ① 縁の減光: 実物の膜も縁ほど透過率が落ちる（フレネル反射の裏返し）
///  ② 右下の陰: 光源は左上（グロスの位置）なので陰は対角へ
struct BubbleShadingOverlay: View {
    /// 基準72ptに対するスケール
    var s: CGFloat
    /// 外観ぶんを掛けた強さ
    var strength: Double

    /// 陰の色。黒だと「汚れ」に見えるので、ガラスらしい寒色グレーにする
    private let shade = Color(red: 0.34, green: 0.39, blue: 0.50)

    var body: some View {
        if strength > 0.001 {
            ZStack {
                // ① 縁の減光（limb darkening）
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.55),
                            .init(color: shade.opacity(0.07 * strength), location: 0.80),
                            .init(color: shade.opacity(0.21 * strength), location: 0.93),
                            .init(color: shade.opacity(0.34 * strength), location: 1.0),
                        ]),
                        center: .center, startRadius: 0, endRadius: 36 * s
                    ))
                // ② 右下の陰（光源の対角）。中心を外して球の丸みを作る
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: shade.opacity(0.08 * strength), location: 0.55),
                            .init(color: shade.opacity(0.20 * strength), location: 1.0),
                        ]),
                        center: UnitPoint(x: 0.74, y: 0.78),
                        startRadius: 0, endRadius: 52 * s
                    ))
            }
            .frame(width: 72 * s, height: 72 * s)
            .blendMode(.multiply)
        }
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
                    gradient: Gradient(stops: filmBandStops(peak: BubbleRainbowStrength.value)),
                    center: .center, startRadius: 0, endRadius: 36 * s
                )))
                .blendMode(.screen)
                .opacity(1.0)

            // ── 薄膜干渉（減算側）: 白い背景では screen(白, 色) = 白 で加算の虹が
            //    完全に消える。実物の膜は反射（加算）と同時に透過光から補色を
            //    抜くので、同じ帯を multiply でも重ねる。暗い背景では
            //    「暗い値 × 色 ≒ 暗い値」でほぼ無効になり、見た目を壊さない
            if BubbleRainbowSubtractive.value > 0.001 {
                Circle()
                    .fill(LinearGradient(stops: filmStops, startPoint: .top, endPoint: .bottom))
                    .mask(Circle().fill(RadialGradient(
                        gradient: Gradient(stops: filmBandStops(peak: BubbleRainbowStrength.value)),
                        center: .center, startRadius: 0, endRadius: 36 * s
                    )))
                    .blendMode(.multiply)
                    .opacity(BubbleRainbowSubtractive.value)
            }

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

            // ── 縁の減光帯（検証中）: 実物の膜は縁で透過率が落ちる（フレネル反射の裏返し）。
            //    加算の装飾が効かない白背景でも輪郭がうっすら灰色に立つ。通常合成
            if BubbleEdgeVariant.limb {
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.82),
                            .init(color: .black.opacity(0.05), location: 0.92),
                            .init(color: .black.opacity(0.13), location: 1.0),
                        ]),
                        center: .center, startRadius: 0, endRadius: 36 * s
                    ))
            }

            // ── 極細の暗い輪郭線（検証中）: 白背景での視認性担保。
            //    黒背景では暗線が沈んで自然に見えなくなるため外観検出は不要。通常合成
            if BubbleEdgeVariant.hairline {
                Circle()
                    .strokeBorder(
                        Color.black.opacity(BubbleEdgeVariant.value == "combo" ? 0.12 : 0.18),
                        lineWidth: 0.75
                    )
            }
        }
        .frame(width: 72 * s, height: 72 * s)
        .opacity(BubbleDecorationStrength.value)
    }
}
