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
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.022
    shadow.set()

    let squircle = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor(white: 0.90, alpha: 1).setFill()
    squircle.fill()
    NSShadow().set()

    // グレーのガラス面（左上光源のラジアル）— スクエア自体がバブル
    if let sphere = NSGradient(colorsAndLocations:
        (NSColor(white: 0.97, alpha: 1), 0.0),
        (NSColor(white: 0.88, alpha: 1), 0.55),
        (NSColor(white: 0.72, alpha: 1), 1.0)
    ) {
        sphere.draw(in: squircle, relativeCenterPosition: NSPoint(x: -0.4, y: 0.45))
    }

    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()

    // 内側の映り込み（バブルの三日月）: 左上に2本のクレセント
    let rimInset = rect.width * 0.055
    let rimRect = rect.insetBy(dx: rimInset, dy: rimInset)
    let rimPath = NSBezierPath(roundedRect: rimRect, xRadius: cornerRadius * 0.82, yRadius: cornerRadius * 0.82)
    rimPath.lineWidth = rect.width * 0.022
    rimPath.lineCapStyle = .round

    func strokeCrescent(startDeg: CGFloat, endDeg: CGFloat, alpha: CGFloat, width: CGFloat) {
        // 角丸スクエア縁に沿う円弧近似（中心から少し内側の大円）
        let arc = NSBezierPath()
        arc.appendArc(
            withCenter: NSPoint(x: rect.midX, y: rect.midY),
            radius: rect.width * 0.40,
            startAngle: startDeg, endAngle: endDeg, clockwise: false
        )
        arc.lineWidth = width
        arc.lineCapStyle = .round
        NSColor.white.withAlphaComponent(alpha).setStroke()
        arc.stroke()
    }
    strokeCrescent(startDeg: 105, endDeg: 150, alpha: 0.85, width: rect.width * 0.030)
    strokeCrescent(startDeg: 96, endDeg: 122, alpha: 0.55, width: rect.width * 0.016)
    // 右上にも薄い映り込み
    strokeCrescent(startDeg: 40, endDeg: 66, alpha: 0.40, width: rect.width * 0.018)
    // 下の内側反射（大きく淡い弧）
    strokeCrescent(startDeg: 235, endDeg: 305, alpha: 0.30, width: rect.width * 0.020)
    // 左縁のグリント
    let glint = NSBezierPath(ovalIn: NSRect(
        x: rect.minX + rect.width * 0.075, y: rect.midY + rect.height * 0.05,
        width: rect.width * 0.045, height: rect.width * 0.075
    ))
    NSColor.white.withAlphaComponent(0.75).setFill()
    glint.fill()

    NSGraphicsContext.current?.restoreGraphicsState()

    // ✳スパーク（上寄り中央・Claudeオレンジ）
    let sparkCenter = NSPoint(x: rect.midX, y: rect.midY + rect.height * 0.145)
    let sparkR = rect.width * 0.21
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
        var transform = AffineTransform(translationByX: sparkCenter.x, byY: sparkCenter.y)
        transform.rotate(byRadians: angle)
        ray.transform(using: transform)
        star.append(ray)
    }
    claudeOrange.setFill()
    star.fill()

    // Usageゲージ（横バー・下寄り）: グレーのトラック + オレンジの進捗70%
    let barWidth = rect.width * 0.62
    let barHeight = rect.width * 0.085
    let barRect = NSRect(
        x: rect.midX - barWidth / 2,
        y: rect.midY - rect.height * 0.235 - barHeight / 2,
        width: barWidth, height: barHeight
    )
    let track = NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
    NSColor(white: 0.55, alpha: 0.45).setFill()
    track.fill()
    let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: barWidth * 0.70, height: barHeight)
    let fill = NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
    claudeOrange.setFill()
    fill.fill()
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
