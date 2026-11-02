import AppKit
import ScreenCaptureKit

/// 撮影の連続失敗に対する待ち時間。失敗のたびに毎秒やり直すと replayd の負荷になる
struct BackdropFailureBackoff: Equatable {
    static let threshold = 3
    static let firstWait: TimeInterval = 60
    static let maxWait: TimeInterval = 300

    private var failures = 0

    mutating func recordSuccess() { failures = 0 }

    /// 休む秒数を返す。一時的な失敗として流してよい間は nil
    mutating func recordFailure() -> TimeInterval? {
        failures += 1
        guard failures >= Self.threshold else { return nil }
        let doublings = min(failures - Self.threshold, 8)
        return min(Self.firstWait * pow(2, Double(doublings)), Self.maxWait)
    }
}

/// 背景の明暗の判定（テスト可能な純粋関数）。
/// 中間の明るさで外観が往復しないよう、切り替え点に幅を持たせ、同じ判定が続いてから切り替える
struct BackdropTone: Equatable {
    enum Tone { case dark, light }

    private(set) var tone: Tone?
    private var pending: Tone?

    static let darkBelow = 0.42
    static let lightAbove = 0.58

    /// luminance: 0（黒）〜1（白）。確定した明暗を返す
    @discardableResult
    mutating func update(luminance: Double) -> Tone? {
        let target: Tone? = luminance < Self.darkBelow ? .dark : luminance > Self.lightAbove ? .light : nil
        guard let target, target != tone else {
            pending = nil
            return tone
        }
        // 初回はすぐ確定する。以降は2回続いたら切り替える
        if tone == nil || pending == target {
            tone = target
            pending = nil
        } else {
            pending = target
        }
        return tone
    }
}

/// バブルの裏の明るさを測り、球ごとに外観を切り替える（macOS 27 以降・設定でオンのときだけ）。
///
/// 27 で `.regular` の背景追従が無くなったが、ガラスと `.primary` の文字はビューの外観に
/// 追従するので、ビューの外観を切り替えれば 26 に近い見た目になる（2026-11-01 実測）。
/// 裏の明るさは画面収録の許可がないと正確に測れないため、バブルを初めて出す時に一度だけ許可を求める。
/// 読むのは球の範囲だけで、8x8 ピクセルに縮小して平均輝度を計算したら捨てる（保存・送信しない）。
@MainActor
final class BubbleBackdropSampler {
    struct Target {
        let id: Int
        let screenRect: NSRect
        let view: NSView
    }

    private static let interval: TimeInterval = 1
    private static let intervalWithoutPermission: TimeInterval = 10
    /// 撮影が返らなかった後に休む時間。止まった要求は取り消せないので、積み上げない
    private static let suspensionAfterTimeout: TimeInterval = 300
    private static let fadeDuration: CFTimeInterval = 0.45
    private static let captureTimeout: TimeInterval = 2

    /// 測定対象を返す。空ならその回は何もしない
    var targets: () -> [Target] = { [] }
    /// バブルが見えている間だけ true を返す
    var shouldRun: () -> Bool = { false }
    /// 実際に測れていて全部の球の明暗が決まっている間だけ true。可読性の膜の有無に使う
    var onLiveChanged: (Bool) -> Void = { _ in }

    private var task: Task<Void, Never>?
    /// stop → start の直後に古いループが終わっても、新しいループの task を消さないための世代
    private var generation = 0
    private var tones: [Int: BackdropTone] = [:]
    private var content: SCShareableContent?
    private var suspendedUntil: Date = .distantPast
    private var backoff = BackdropFailureBackoff()
    private var screenObserver: NSObjectProtocol?
    /// 許可の問い合わせは1回約5ms掛かるので、許可がある間は聞き直さない（撮影の失敗で聞き直す）
    private var permitted = false
    private var isLive = false {
        didSet { if isLive != oldValue { onLiveChanged(isLive) } }
    }
    #if DEBUG
    var debugLastLuminance: [Int: Double] = [:]
    var debugStage = "idle"
    #endif

    static var isSupported: Bool {
        if #available(macOS 27.0, *) { return usesLiquidGlass }
        return false
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func start() {
        guard Self.isSupported, task == nil else { return }
        if screenObserver == nil {
            // ディスプレイの一覧は構成が変わった時だけ取り直す（毎回の取得は replayd の負荷になる）
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.content = nil }
            }
        }
        generation += 1
        let run = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.shouldRun() else { break }
                if !self.permitted { self.permitted = Self.hasPermission }
                #if DEBUG
                self.debugStage = self.permitted ? "sampling" : "noPermission"
                #endif
                if self.permitted {
                    await self.sampleOnce()
                } else {
                    self.isLive = false
                }
                // 許可を断った人でも既定でこのループに入るので、許可が無い間は間隔を空ける
                try? await Task.sleep(for: .seconds(self.permitted ? Self.interval : Self.intervalWithoutPermission))
            }
            if let self, self.generation == run { self.task = nil }
        }
    }

    /// 測定をやめ、外観をアプリ全体の設定へ戻す
    func stop(resetting views: [NSView]) {
        task?.cancel()
        generation += 1
        suspendedUntil = .distantPast
        backoff = BackdropFailureBackoff()
        task = nil
        tones = [:]
        content = nil
        permitted = false
        isLive = false
        for view in views { view.appearance = nil }
    }

    /// 撮影の失敗を記録する。続くようなら休み、測れていない扱いにして膜を戻す。
    /// 許可が取り消された場合もここに来るので、次の回で聞き直す
    private func recordFailure() {
        content = nil
        permitted = false
        if let wait = backoff.recordFailure() {
            suspendedUntil = Date().addingTimeInterval(wait)
            isLive = false
        }
    }

    private func sampleOnce() async {
        #if DEBUG
        debugStage = targets().isEmpty ? "noTargets" : "awaitContent"
        #endif
        guard !targets().isEmpty, Date() >= suspendedUntil else { return }
        if content == nil {
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                #if DEBUG
                debugStage = "contentError: \(error)"
                #endif
                recordFailure()
            }
        }
        guard let content else { return }
        var capturedAny = false
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }

        for target in targets() {
            // バブルの窓が一覧に載る前に取った一覧では、自分を除外できず（球自体を測ってしまう）、
            // captureImage が返らないことも実測した。載るまで取り直す
            let windowNumber = target.view.window?.windowNumber ?? -1
            guard !ownApps.isEmpty || ownWindows.contains(where: { Int($0.windowID) == windowNumber }) else {
                #if DEBUG
                debugStage = "waitingForOwnWindow"
                #endif
                self.content = nil
                return
            }
            // AppKit（左下原点）→ ScreenCaptureKit（左上原点のグローバル座標）
            let r = target.screenRect
            let rect = CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(center) }) else {
                #if DEBUG
                debugStage = "noDisplay center=\(center) displays=\(content.displays.map(\.frame))"
                #endif
                continue
            }

            // スリープ中のディスプレイを撮ると、画像もエラーも無い完了が報告されている
            guard CGDisplayIsAsleep(display.displayID) == 0 else { continue }

            // 自分のウィンドウを除いた「裏側」だけを読む
            let filter = ownApps.isEmpty
                ? SCContentFilter(display: display, excludingWindows: ownWindows)
                : SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                .intersection(CGRect(origin: .zero, size: display.frame.size))
            config.width = 8
            config.height = 8
            config.showsCursor = false
            #if DEBUG
            debugStage = "awaitCapture rect=\(config.sourceRect) display=\(display.frame) ownApps=\(ownApps.count)"
            #endif
            guard !config.sourceRect.isEmpty else { continue }
            let result = await Self.captureImage(filter: filter, config: config)
            var captured: CGImage?
            switch result {
            case .image(let image):
                captured = image
                capturedAny = true
                backoff.recordSuccess()
            case .failed:
                recordFailure() // 次回は一覧から取り直す
            case .timedOut:
                self.content = nil
                suspendedUntil = Date().addingTimeInterval(Self.suspensionAfterTimeout)
                isLive = false
                return
            }
            #if DEBUG
            if captured != nil { debugStage = "captured" }
            #endif
            guard let image = captured,
                  let luminance = Self.averageLuminance(of: image),
                  shouldRun() else { continue }

            #if DEBUG
            debugLastLuminance[target.id] = luminance
            #endif
            var tone = tones[target.id] ?? BackdropTone()
            let decided = tone.update(luminance: luminance)
            tones[target.id] = tone
            let name: NSAppearance.Name? = decided.map { $0 == .dark ? .darkAqua : .aqua }
            if let name, target.view.appearance?.name != name {
                Self.fadeAppearance(of: target.view, to: name)
            }
        }
        if capturedAny {
            let current = targets()
            isLive = !current.isEmpty && current.allSatisfy { tones[$0.id]?.tone != nil }
        }
    }

    /// 外観をフェードで切り替える。CATransition は追加時の描画と次のコミット時の描画を
    /// クロスフェードするので、SwiftUI の更新をこの場で済ませてからコミットさせる
    private static func fadeAppearance(of view: NSView, to name: NSAppearance.Name) {
        let isFirstDecision = view.appearance == nil
        if !isFirstDecision, let layer = view.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = fadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "appearanceFade")
        }
        view.appearance = NSAppearance(named: name)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    /// 制限時間つきの撮影。captureImage は条件次第で返らないことがあるため、
    /// 待ち続けて以後の測定が全部止まる事態を防ぐ
    /// async 版は画像もエラーも無い完了でトラップする報告があるので、completion 版を使う
    private static func captureImage(filter: SCContentFilter, config: SCStreamConfiguration) async -> CaptureResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<CaptureResult, Never>) in
            let once = ResumeOnce(continuation)
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                once.resume(image.map(CaptureResult.image) ?? .failed)
            }
            Task {
                try? await Task.sleep(for: .seconds(captureTimeout))
                once.resume(.timedOut)
            }
        }
    }

    private enum CaptureResult: @unchecked Sendable {
        case image(CGImage)
        case failed
        case timedOut
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CaptureResult, Never>?
        init(_ continuation: CheckedContinuation<CaptureResult, Never>) { self.continuation = continuation }
        func resume(_ result: CaptureResult) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: result)
        }
    }

    static func averageLuminance(of image: CGImage) -> Double? {
        let width = 8, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
        }
        return total / Double(width * height) / 255
    }
}
