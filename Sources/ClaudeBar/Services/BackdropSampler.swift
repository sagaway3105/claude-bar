import AppKit
import ScreenCaptureKit

/// バブル背後の画面輝度をサンプリングする（文字色の動的切り替え用）。
/// 画面収録の権限が必要。未許可・失敗時は nil を返し、UIは従来の固定色にフォールバックする。
enum BackdropSampler {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// rect（グローバルCocoa座標）の平均輝度(0-1)。自アプリのウィンドウは除外して背後だけを読む
    static func averageLuminance(of rect: NSRect) async -> Double? {
        guard hasPermission else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        ) else { return nil }

        // Cocoa（左下原点）→ CG（プライマリ左上原点・y下向き）のグローバル座標へ
        guard let primary = NSScreen.screens.first else { return nil }
        let cgRect = CGRect(
            x: rect.origin.x,
            y: primary.frame.maxY - rect.maxY,
            width: rect.width, height: rect.height
        )
        guard let display = content.displays.first(where: { $0.frame.intersects(cgRect) }) else { return nil }

        let ourPID = ProcessInfo.processInfo.processIdentifier
        let ours = content.applications.filter { $0.processID == ourPID }
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.sourceRect = cgRect.offsetBy(dx: -display.frame.origin.x, dy: -display.frame.origin.y)
        config.width = 8
        config.height = 8
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        ) else { return nil }
        return luminance(of: image)
    }

    private static func luminance(of image: CGImage) -> Double? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let bytesPerPixel = 4
        var data = [UInt8](repeating: 0, count: w * h * bytesPerPixel)
        guard let ctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * bytesPerPixel, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var total = 0.0
        for i in stride(from: 0, to: data.count, by: bytesPerPixel) {
            let r = Double(data[i]) / 255
            let g = Double(data[i + 1]) / 255
            let b = Double(data[i + 2]) / 255
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return total / Double(w * h)
    }
}
