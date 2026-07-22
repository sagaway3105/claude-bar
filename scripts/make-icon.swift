// アプリアイコン生成: クリーム地の角丸スクエア + ガラス玉バブル（スパーク+使用量アーク）
// 使い方: swift scripts/make-icon.swift <出力ディレクトリ>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets"
let iconsetPath = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let claudeOrange = NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1)

func drawIcon(size s: CGFloat) {
    // アイコン形状（Appleガイドラインに近い比率: 全体の~82%を占める角丸スクエア）
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = rect.width * 0.225

    // 外形のドロップシャドウ
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.022
    shadow.set()

    let squircle = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor(red: 0.957, green: 0.937, blue: 0.898, alpha: 1).setFill()
    squircle.fill()
    NSShadow().set()

    // クリーム地の縦グラデーション
    if let gradient = NSGradient(
        colors: [
            NSColor(red: 0.976, green: 0.961, blue: 0.933, alpha: 1),
            NSColor(red: 0.925, green: 0.894, blue: 0.839, alpha: 1),
        ]
    ) {
        gradient.draw(in: squircle, angle: -90)
    }

    // ---- ガラス玉バブル ----
    let center = NSPoint(x: s / 2, y: s / 2)
    let ballR = rect.width * 0.335
    let ballRect = NSRect(x: center.x - ballR, y: center.y - ballR, width: ballR * 2, height: ballR * 2)
    let ball = NSBezierPath(ovalIn: ballRect)

    // 球の落ち影（下方向・柔らかく）
    let ballShadow = NSShadow()
    ballShadow.shadowColor = NSColor(red: 0.45, green: 0.32, blue: 0.24, alpha: 0.30)
    ballShadow.shadowOffset = NSSize(width: 0, height: -ballR * 0.16)
    ballShadow.shadowBlurRadius = ballR * 0.22
    ballShadow.set()
    NSColor.white.withAlphaComponent(0.10).setFill()
    ball.fill()
    NSShadow().set()

    // 球体の面: 左上光源のラジアルグラデーション（ガラスの透け感）
    if let sphere = NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.92), 0.0),
        (NSColor.white.withAlphaComponent(0.38), 0.45),
        (NSColor(red: 0.82, green: 0.78, blue: 0.74, alpha: 0.40), 0.85),
        (NSColor.white.withAlphaComponent(0.55), 1.0)
    ) {
        sphere.draw(in: ball, relativeCenterPosition: NSPoint(x: -0.38, y: 0.42))
    }

    // 底のコースティクス（下内縁の明るい帯）
    NSGraphicsContext.current?.saveGraphicsState()
    ball.addClip()
    if let caustic = NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.55), 0.0),
        (NSColor.white.withAlphaComponent(0.0), 0.35)
    ) {
        let causticRect = NSRect(
            x: ballRect.minX, y: ballRect.minY,
            width: ballRect.width, height: ballRect.height * 0.5
        )
        caustic.draw(in: NSBezierPath(rect: causticRect), angle: 90)
    }
    NSGraphicsContext.current?.restoreGraphicsState()

    // リム（ガラスの縁）
    NSColor.white.withAlphaComponent(0.85).setStroke()
    let rim = NSBezierPath(ovalIn: ballRect.insetBy(dx: ballR * 0.012, dy: ballR * 0.012))
    rim.lineWidth = max(1, ballR * 0.035)
    rim.stroke()

    // 使用量アーク（12時から時計回りに65%・Claudeオレンジ）
    let arcR = ballR * 0.78
    let arc = NSBezierPath()
    arc.appendArc(
        withCenter: center, radius: arcR,
        startAngle: 90, endAngle: 90 - 360 * 0.65, clockwise: true
    )
    arc.lineWidth = ballR * 0.13
    arc.lineCapStyle = .round
    claudeOrange.setStroke()
    arc.stroke()

    // 中央のスパーク（アプリ内StarburstShapeと同形状・小さめ）
    let sparkR = ballR * 0.42
    let lengths: [CGFloat] = [1.0, 0.68, 0.88, 0.74, 1.0, 0.66, 0.90, 0.72, 0.97, 0.68, 0.86, 0.74]
    let angleJitter: [CGFloat] = [0, 0.05, -0.04, 0.03, 0, -0.05, 0.04, 0, -0.03, 0.05, -0.04, 0.03]
    let rayWidth = sparkR * 0.15
    let star = NSBezierPath()
    for i in 0..<lengths.count {
        let angle = CGFloat(i) / CGFloat(lengths.count) * 2 * .pi - .pi / 2 + angleJitter[i]
        let ray = NSBezierPath(
            roundedRect: NSRect(x: 0, y: -rayWidth / 2, width: sparkR * lengths[i], height: rayWidth),
            xRadius: rayWidth / 2, yRadius: rayWidth / 2
        )
        var transform = AffineTransform(translationByX: center.x, byY: center.y)
        transform.rotate(byRadians: angle)
        ray.transform(using: transform)
        star.append(ray)
    }
    claudeOrange.setFill()
    star.fill()

    // スペキュラハイライト（左上・大小2枚）
    NSGraphicsContext.current?.saveGraphicsState()
    let bloom = NSBezierPath(ovalIn: NSRect(
        x: center.x - ballR * 0.62, y: center.y + ballR * 0.28,
        width: ballR * 0.52, height: ballR * 0.30
    ))
    var tilt = AffineTransform(translationByX: center.x - ballR * 0.36, byY: center.y + ballR * 0.43)
    tilt.rotate(byDegrees: 32)
    tilt.translate(x: -(center.x - ballR * 0.36), y: -(center.y + ballR * 0.43))
    bloom.transform(using: tilt)
    NSColor.white.withAlphaComponent(0.85).setFill()
    bloom.fill()
    let glint = NSBezierPath(ovalIn: NSRect(
        x: center.x + ballR * 0.38, y: center.y - ballR * 0.60,
        width: ballR * 0.14, height: ballR * 0.14
    ))
    NSColor.white.withAlphaComponent(0.55).setFill()
    glint.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
}

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    drawIcon(size: CGFloat(pixels))
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for entry in entries {
    guard let data = render(pixels: entry.pixels) else {
        FileHandle.standardError.write("render failed: \(entry.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = URL(fileURLWithPath: "\(iconsetPath)/\(entry.name).png")
    try! data.write(to: url)
}
print("✅ \(iconsetPath) を生成しました")
