// アプリアイコン生成: クリーム地の角丸スクエア + Claudeオレンジのサンバースト
// 使い方: swift scripts/make-icon.swift <出力ディレクトリ>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets"
let iconsetPath = "\(outDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func drawIcon(size s: CGFloat) {
    // アイコン形状（Appleガイドラインに近い比率: 全体の~82%を占める角丸スクエア）
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = rect.width * 0.225

    // ドロップシャドウ
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.022
    shadow.set()

    let squircle = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor(red: 0.957, green: 0.937, blue: 0.898, alpha: 1).setFill()
    squircle.fill()
    NSShadow().set()

    // 上から下への微妙なグラデーション
    if let gradient = NSGradient(
        colors: [
            NSColor(red: 0.973, green: 0.957, blue: 0.925, alpha: 1),
            NSColor(red: 0.933, green: 0.906, blue: 0.855, alpha: 1),
        ]
    ) {
        gradient.draw(in: squircle, angle: -90)
    }

    // サンバースト（アプリ内のStarburstShapeと同じ形状）
    let center = NSPoint(x: s / 2, y: s / 2)
    let radius = rect.width * 0.34
    let innerRadius = radius * 0.13
    let rays = 9
    let lengths: [CGFloat] = [1.0, 0.78, 0.93, 0.84, 1.0, 0.8, 0.95, 0.82, 0.9]
    let baseHalfAngle = CGFloat.pi / CGFloat(rays) * 0.6
    let tipHalfAngle = baseHalfAngle * 0.42

    func point(_ r: CGFloat, _ angle: CGFloat) -> NSPoint {
        NSPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
    }

    let star = NSBezierPath()
    for i in 0..<rays {
        let angle = CGFloat(i) / CGFloat(rays) * 2 * .pi - .pi / 2
        let length = radius * lengths[i % lengths.count]
        star.move(to: point(innerRadius, angle - baseHalfAngle))
        star.line(to: point(length, angle - tipHalfAngle))
        star.line(to: point(length, angle + tipHalfAngle))
        star.line(to: point(innerRadius, angle + baseHalfAngle))
        star.close()
    }
    let dotRadius = innerRadius * 1.35
    star.appendOval(in: NSRect(
        x: center.x - dotRadius, y: center.y - dotRadius,
        width: dotRadius * 2, height: dotRadius * 2
    ))
    NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1).setFill()
    star.fill()
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
