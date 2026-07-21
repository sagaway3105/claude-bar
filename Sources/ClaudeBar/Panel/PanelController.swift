import AppKit
import QuartzCore
import SwiftUI

/// パネル/バブルのウィンドウ制御。
/// - attached: メニューバー直下（外側クリックで閉じる）
/// - bubble:   画面全体をゆっくり漂う常時最前面のバブル
/// - floating: バブルから展開したフローティングパネル
///
/// バブルモードではウィンドウを画面サイズの透明レイヤーとして固定し、
/// ガラス+コンテンツの「アセンブリ」だけを動かす。
/// ドリフト軌道は数秒分を物理シミュレーションで先読みし、CAKeyframeAnimationとして
/// レンダーサーバに渡す — 補間はOS側でディスプレイのリフレッシュレート（ProMotionなら120Hz）
/// で行われるため、アプリのメインスレッドが詰まっても滑らかさが保証される。
/// カーソルがバブル上にある時だけクリックを受け付け、それ以外はクリック透過。
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let state: AppState
    private let usageService: UsageService
    private let settings: SettingsStore

    /// StatusItemControllerから注入される（吸着判定・デフォルト位置用）
    var statusButtonFrame: (() -> NSRect?)?
    var onOpenSettings: (() -> Void)?

    private(set) lazy var uiActions: PanelActions = makeActions()

    private var panel: NSPanel?
    private var containerView: PassthroughContainerView?
    private var assemblyView: NSView?
    private var glassView: NSGlassEffectView?
    private var contentHosting: NSHostingView<PanelRootView>?
    private var popWindow: NSWindow?

    private var attachedOrigin = NSPoint.zero
    private var isProgrammaticMove = false
    private var clickMonitors: [Any] = []
    private var isPopping = false
    private var isBubbleChrome = false
    private var lastPanelSize = NSSize(width: 240, height: 380)
    private var lastBubbleCenter: NSPoint?
    private var revivalTask: Task<Void, Never>?

    // 浮遊状態（アンカー周辺を、無限リピートの加算アニメーションで漂う）
    private var floatAnchor = NSPoint.zero  // アセンブリ原点（ウィンドウ座標）
    private var driftBounds = NSRect.zero   // ドラッグ可能範囲（ウィンドウ座標）
    private var dragStartAnchor: NSPoint?
    private var isDraggingBubble = false
    private var wasHoveringBubble = false
    private var lastHoverBounceAt = Date.distantPast
    private var mouseTrackTimer: Timer?
    private var napActivity: NSObjectProtocol?

    private let panelWidth: CGFloat = 240
    private let bubbleDiameter: CGFloat = 76
    private let panelCornerRadius: CGFloat = 24
    private let detachThreshold: CGFloat = 30
    private let snapMargin: CGFloat = 60

    var debugPanelFrame: NSRect? {
        if isBubbleChrome { return assemblyScreenFrame }
        return panel?.frame
    }
    var debugPanelVisible: Bool { panel?.isVisible ?? false }

    init(state: AppState, usageService: UsageService, settings: SettingsStore) {
        self.state = state
        self.usageService = usageService
        self.settings = settings
        super.init()
    }

    /// バブルが表示している使用量ウィンドウ（設定で選択）
    private var bubbleUsageWindow: UsageWindow? {
        state.usage?.window(for: settings.bubbleMetric)
    }

    /// アセンブリの現在のスクリーン座標（アニメーション中はpresentation layerが真実）
    private var assemblyScreenFrame: NSRect? {
        guard let p = panel, let assembly = assemblyView else { return nil }
        var rect = assembly.frame
        if let presentation = assembly.layer?.presentation() {
            // macOSのlayer-backed viewはanchorPoint(0,0)なので position == frame.origin
            rect.origin = NSPoint(x: presentation.position.x, y: presentation.position.y)
        }
        return p.convertToScreen(rect)
    }

    // MARK: - メニューバーから

    func toggle(relativeTo button: NSStatusBarButton) {
        if let panel, panel.isVisible {
            if state.mode == .attached {
                hide()
            } else {
                panel.orderFrontRegardless()
            }
            return
        }
        showAttached(relativeTo: button)
    }

    // MARK: - ウィンドウ生成

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 380),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.animationBehavior = .none
        p.delegate = self

        let container = PassthroughContainerView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 380))
        container.wantsLayer = true

        // 「アセンブリ」= 動かす単位。ガラスのcontentViewに内容を入れる
        // （alphaを下げたりコンテンツを外に出すとLiquid Glassのブラー/屈折が無効化されるため、
        //   透明感は style = .clear に任せる）
        let assembly = NSView(frame: container.bounds)
        assembly.wantsLayer = true
        assembly.autoresizingMask = [.width, .height]

        let glass = NSGlassEffectView(frame: assembly.bounds)
        glass.cornerRadius = panelCornerRadius
        glass.style = .clear // 透明で背後を屈折させるLiquid Glass
        glass.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(
            rootView: PanelRootView(state: state, settings: settings, actions: uiActions)
        )
        glass.contentView = hosting

        assembly.addSubview(glass)
        container.addSubview(assembly)
        p.contentView = container

        panel = p
        containerView = container
        assemblyView = assembly
        glassView = glass
        contentHosting = hosting
        return p
    }

    private func makeActions() -> PanelActions {
        PanelActions(
            refresh: { [weak self] in
                guard let self else { return }
                Task { await self.usageService.refresh() }
            },
            quit: { NSApp.terminate(nil) },
            toBubble: { [weak self] in
                guard let self, let panel = self.panel else { return }
                self.becomeBubble(at: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
            },
            expand: { [weak self] in self?.expandFromBubble() },
            backToMenuBar: { [weak self] in
                guard let self else { return }
                self.state.mode = .attached
                self.hide()
            },
            pop: { [weak self] in self?.popBubble() },
            settings: { [weak self] in self?.onOpenSettings?() },
            login: { [weak self] in self?.openLoginHelper() },
            contentHeightChanged: { [weak self] height in self?.contentHeightChanged(height) }
        )
    }

    /// ターミナルで claude /login を起動する（失敗時はコマンドをコピーしてターミナルを開く）
    private func openLoginHelper() {
        let source = """
        tell application "Terminal"
            activate
            do script "claude /login"
        end tell
        """
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if error == nil { return }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("claude /login", forType: .string)
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: terminalURL, configuration: .init(), completionHandler: nil)
    }

    // MARK: - バブル用クローム（画面サイズの固定ウィンドウ + 漂うアセンブリ）

    private func enterBubbleChrome(centeredAt center: NSPoint) {
        guard let p = panel, let assembly = assemblyView, let glass = glassView else { return }
        isBubbleChrome = true
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        isProgrammaticMove = true
        p.setFrame(screenFrame, display: true)
        isProgrammaticMove = false
        p.hasShadow = false // アセンブリ移動のたびに影を再計算させない

        assembly.autoresizingMask = []
        floatAnchor = NSPoint(
            x: center.x - screenFrame.origin.x - bubbleDiameter / 2,
            y: center.y - screenFrame.origin.y - bubbleDiameter / 2
        )
        wasHoveringBubble = false
        assembly.frame = NSRect(origin: floatAnchor, size: NSSize(width: bubbleDiameter, height: bubbleDiameter))
        glass.cornerRadius = bubbleDiameter / 2

        // 移動可能範囲: メニューバーとDockを避けた可視領域
        let vf = screen?.visibleFrame ?? screenFrame
        driftBounds = NSRect(
            x: vf.minX - screenFrame.minX + 4,
            y: vf.minY - screenFrame.minY + 4,
            width: vf.width - bubbleDiameter - 8,
            height: vf.height - bubbleDiameter - 8
        )
        startMouseTracking()
        installBubbleMouseMonitor()
        // アクセサリアプリはApp Napでタイマーが間引かれるため、バブル表示中は抑止する
        if napActivity == nil {
            napActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated], reason: "Bubble drift animation"
            )
        }
    }

    /// パネルモードへ戻す: ウィンドウをアセンブリにぴったり合わせ、autoresizeを復帰
    private func exitBubbleChrome() {
        guard isBubbleChrome, let p = panel, let assembly = assemblyView, let container = containerView else { return }
        stopDrifting()
        isBubbleChrome = false
        stopMouseTracking()
        removeBubbleMouseMonitor()
        p.ignoresMouseEvents = false
        let assemblyOnScreen = p.convertToScreen(assembly.frame)
        isProgrammaticMove = true
        p.setFrame(assemblyOnScreen, display: false)
        isProgrammaticMove = false
        p.hasShadow = true
        assembly.autoresizingMask = [.width, .height]
        assembly.frame = container.bounds
    }

    /// 非表示のままクロームを解除（pop後・吸着後など）
    private func resetChromeAfterHide() {
        guard isBubbleChrome, let p = panel, let assembly = assemblyView, let container = containerView else { return }
        stopDrifting()
        isBubbleChrome = false
        stopMouseTracking()
        removeBubbleMouseMonitor()
        p.ignoresMouseEvents = false
        isProgrammaticMove = true
        p.setFrame(NSRect(origin: p.frame.origin, size: lastPanelSize), display: false)
        isProgrammaticMove = false
        p.hasShadow = true
        assembly.autoresizingMask = [.width, .height]
        assembly.frame = container.bounds
        assembly.alphaValue = 1
    }

    /// カーソルがバブル上にある時だけクリックを受け付ける
    private func startMouseTracking() {
        stopMouseTracking()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTrackTimer = timer
        trackMouse()
    }

    private func trackMouse() {
        guard isBubbleChrome, let p = panel else { return }
        guard let bubbleOnScreen = assemblyScreenFrame?.insetBy(dx: -6, dy: -6) else { return }
        let inside = bubbleOnScreen.contains(NSEvent.mouseLocation)
        if p.ignoresMouseEvents != !inside {
            p.ignoresMouseEvents = !inside
        }
        // ホバーで「ポヨン」
        if inside, !wasHoveringBubble, !dragActive,
           Date().timeIntervalSince(lastHoverBounceAt) > 0.6 {
            lastHoverBounceAt = Date()
            state.hoverBounce += 1
        }
        wasHoveringBubble = inside
    }

    private func stopMouseTracking() {
        mouseTrackTimer?.invalidate()
        mouseTrackTimer = nil
        if let activity = napActivity {
            ProcessInfo.processInfo.endActivity(activity)
            napActivity = nil
        }
    }

    // MARK: - attached（メニューバー直下）

    private func showAttached(relativeTo button: NSStatusBarButton) {
        let p = ensurePanel()
        cancelPendingHide()
        exitBubbleChrome()
        state.mode = .attached
        p.isMovableByWindowBackground = false
        p.level = .popUpMenu
        glassView?.cornerRadius = panelCornerRadius
        assemblyView?.alphaValue = 1

        // @Observableの反映を待ってからサイズを測る
        DispatchQueue.main.async { [weak self] in
            guard let self, let p = self.panel else { return }
            self.contentHosting?.layoutSubtreeIfNeeded()
            var size = self.contentHosting?.fittingSize ?? self.lastPanelSize
            size.width = self.panelWidth
            if size.height < 200 { size.height = self.lastPanelSize.height }
            self.lastPanelSize = size

            guard let buttonWindow = button.window else { return }
            let screen = buttonWindow.screen ?? NSScreen.main
            let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            var x = buttonRect.midX - size.width / 2
            if let screen {
                x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - size.width - 8)
            }
            let y = buttonRect.minY - size.height - 6

            self.isProgrammaticMove = true
            p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
            self.isProgrammaticMove = false
            self.attachedOrigin = NSPoint(x: x, y: y)

            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                p.animator().alphaValue = 1
            }
            self.installDismissMonitors()
            self.usageService.refreshIfStale(olderThan: 45)
        }
    }

    /// コンテンツの実高さが変わったらウィンドウを上端固定で追従させる
    private func contentHeightChanged(_ height: CGFloat) {
        guard let p = panel, p.isVisible, state.mode != .bubble,
              !isProgrammaticMove, height > 100 else { return }
        let frame = p.frame
        guard abs(frame.height - height) > 2 else { return }
        let newFrame = NSRect(x: frame.origin.x, y: frame.maxY - height, width: frame.width, height: height)
        isProgrammaticMove = true
        p.setFrame(newFrame, display: true)
        isProgrammaticMove = false
        lastPanelSize = newFrame.size
        if state.mode == .attached { attachedOrigin = newFrame.origin }
    }

    // MARK: - バブル（浮遊モード）

    /// tear-off・🫧ボタン経由（パネル表示中からの変形）
    func becomeBubble(at point: NSPoint) {
        guard state.mode != .bubble, let p = panel else { return }
        cancelPendingHide()
        revivalTask?.cancel()
        state.mode = .bubble
        state.detachBounce += 1
        removeDismissMonitors()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

        glassView?.cornerRadius = bubbleDiameter / 2
        p.level = .floating
        p.isMovableByWindowBackground = false

        // まずウィンドウごとバブルサイズへ縮め、完了後に画面サイズの固定ウィンドウ構成へ差し替える（見た目は不変）
        let tight = NSRect(
            x: point.x - bubbleDiameter / 2, y: point.y - bubbleDiameter / 2,
            width: bubbleDiameter, height: bubbleDiameter
        )
        animateFrame(to: tight) { [weak self] in
            guard let self, self.state.mode == .bubble, let p = self.panel else { return }
            self.enterBubbleChrome(centeredAt: NSPoint(x: p.frame.midX, y: p.frame.midY))
            self.startDrifting()
        }
    }

    /// 非表示状態から直接バブルを出す（右クリックメニュー・復活・デバッグ）
    func showBubble(at point: NSPoint, poppingIn: Bool = false) {
        let p = ensurePanel()
        cancelPendingHide()
        revivalTask?.cancel()
        removeDismissMonitors()
        state.mode = .bubble
        assemblyView?.alphaValue = 1
        p.alphaValue = 1
        p.level = .floating
        p.isMovableByWindowBackground = false
        enterBubbleChrome(centeredAt: point)

        guard let assembly = assemblyView else { return }
        if poppingIn {
            // ぽわんっと出現（ウィンドウは固定、アセンブリだけ膨らむ）
            let target = assembly.frame
            assembly.frame = NSRect(x: target.midX - 4, y: target.midY - 4, width: 8, height: 8)
            assembly.alphaValue = 0
            p.orderFrontRegardless()
            state.detachBounce += 1
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.34
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.18)
                assembly.animator().frame = target
                assembly.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.startDrifting() }
            })
        } else {
            p.orderFrontRegardless()
            startDrifting()
        }
    }

    func showBubbleNearStatusItem() {
        showBubble(at: defaultBubblePoint(), poppingIn: true)
    }

    private func defaultBubblePoint() -> NSPoint {
        if let bf = statusButtonFrame?() {
            return NSPoint(x: bf.midX, y: bf.minY - 90)
        }
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            return NSPoint(x: vf.maxX - 100, y: vf.maxY - 100)
        }
        return NSPoint(x: 300, y: 300)
    }

    func expandFromBubble() {
        guard state.mode == .bubble, let p = panel else { return }
        state.mode = .floating
        exitBubbleChrome()
        glassView?.cornerRadius = panelCornerRadius
        p.isMovableByWindowBackground = true

        DispatchQueue.main.async { [weak self] in
            guard let self, let p = self.panel else { return }
            self.contentHosting?.layoutSubtreeIfNeeded()
            var size = self.contentHosting?.fittingSize ?? self.lastPanelSize
            size.width = self.panelWidth
            if size.height < 200 { size.height = self.lastPanelSize.height }
            self.lastPanelSize = size

            let bubbleFrame = p.frame
            var origin = NSPoint(
                x: bubbleFrame.midX - size.width / 2,
                y: bubbleFrame.maxY - size.height
            )
            if let screen = p.screen ?? NSScreen.main {
                let vf = screen.visibleFrame
                origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
                origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
            }
            self.animateFrame(to: NSRect(origin: origin, size: size))
        }
    }

    // MARK: - 浮遊（アンカー周辺・無限リピートの加算アニメーション）

    /// 周期の異なる正弦波（easeInEaseOutのautoreverse）を加算合成してその場でゆったり漂わせる。
    /// レンダーサーバ側で無限に補間されるため、繋ぎ目もフレーム落ちも存在しない。
    private func startDrifting() {
        guard state.mode == .bubble, isBubbleChrome, !isPopping,
              let assembly = assemblyView, let layer = assembly.layer else { return }
        guard layer.animation(forKey: "float-x1") == nil else { return }

        func floatAnimation(_ keyPath: String, amplitude: CGFloat, duration: CFTimeInterval, phase: CFTimeInterval) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = -amplitude
            animation.toValue = amplitude
            animation.duration = duration
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.isAdditive = true
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // 中間点（オフセット0）から始めて出現時のジャンプを防ぐ + 位相をずらして有機的に
            animation.timeOffset = duration / 2 + phase
            return animation
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.add(floatAnimation("position.x", amplitude: 6, duration: 3.7, phase: 0), forKey: "float-x1")
        layer.add(floatAnimation("position.x", amplitude: 2.5, duration: 6.1, phase: 1.7), forKey: "float-x2")
        layer.add(floatAnimation("position.y", amplitude: 7, duration: 4.4, phase: 1.1), forKey: "float-y1")
        layer.add(floatAnimation("position.y", amplitude: 2.5, duration: 7.9, phase: 3.0), forKey: "float-y2")
        CATransaction.commit()
    }

    private func stopDrifting() {
        dragStartAnchor = nil
        isDraggingBubble = false
        guard let assembly = assemblyView, let layer = assembly.layer else { return }
        if isBubbleChrome, let presentation = layer.presentation() {
            // 現在の表示位置で静止させる
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            assembly.setFrameOrigin(NSPoint(x: presentation.position.x, y: presentation.position.y))
            CATransaction.commit()
        }
        for key in ["float-x1", "float-x2", "float-y1", "float-y2"] {
            layer.removeAnimation(forKey: key)
        }
        if isBubbleChrome {
            floatAnchor = assembly.frame.origin
        }
    }

    // MARK: - バブルの操作（AppKitレベルのマウス処理: クリック=展開 / ドラッグ=移動）

    private var bubbleMouseMonitor: Any?
    private var dragActive = false
    private var dragMoved = false
    private var dragStartMouse = NSPoint.zero

    private func installBubbleMouseMonitor() {
        removeBubbleMouseMonitor()
        bubbleMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleBubbleMouse(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeBubbleMouseMonitor() {
        if let monitor = bubbleMouseMonitor {
            NSEvent.removeMonitor(monitor)
            bubbleMouseMonitor = nil
        }
        dragActive = false
    }

    private func handleBubbleMouse(_ event: NSEvent) -> Bool {
        guard isBubbleChrome, let p = panel, event.window === p else { return false }
        switch event.type {
        case .leftMouseDown:
            guard let frame = assemblyScreenFrame,
                  frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) else { return false }
            dragActive = true
            dragMoved = false
            isDraggingBubble = true
            dragStartMouse = NSEvent.mouseLocation
            dragStartAnchor = floatAnchor
            return true
        case .leftMouseDragged:
            guard dragActive, let start = dragStartAnchor else { return false }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - dragStartMouse.x
            let dy = mouse.y - dragStartMouse.y
            if hypot(dx, dy) > 3 { dragMoved = true }
            var pos = NSPoint(x: start.x + dx, y: start.y + dy)
            pos.x = min(max(pos.x, driftBounds.minX), driftBounds.maxX)
            pos.y = min(max(pos.y, driftBounds.minY), driftBounds.maxY)
            floatAnchor = pos
            // 加算アニメーションはこの上に乗り続けるので、ドラッグ中もゆらゆらしたまま
            assemblyView?.setFrameOrigin(pos)
            return true
        case .leftMouseUp:
            guard dragActive else { return false }
            dragActive = false
            isDraggingBubble = false
            dragStartAnchor = nil
            if !dragMoved {
                expandFromBubble() // 動かさず放した = クリック → パネルに展開
            } else if let buttonFrame = statusButtonFrame?(), let onScreen = assemblyScreenFrame {
                // メニューバー付近で放したら吸着して戻る
                let zone = buttonFrame.insetBy(dx: -snapMargin, dy: -snapMargin)
                if zone.contains(NSPoint(x: onScreen.midX, y: onScreen.midY)) {
                    snapBackToMenuBar(buttonFrame: buttonFrame)
                }
            }
            return true
        default:
            return false
        }
    }

    // MARK: - 割れる（100%）と復活

    func popBubble() {
        guard state.mode == .bubble, !isPopping, let assembly = assemblyView else { return }
        isPopping = true
        stopDrifting()
        if let onScreen = assemblyScreenFrame {
            lastBubbleCenter = NSPoint(x: onScreen.midX, y: onScreen.midY)
        }

        NSSound(named: "Pop")?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        if let center = lastBubbleCenter {
            showPopBurst(centeredOn: center)
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            assembly.animator().alphaValue = 0
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            guard let self else { return }
            self.state.mode = .attached
            self.hide()
            self.isPopping = false
            self.scheduleRevivalIfNeeded()
        }
    }

    /// 設定が有効なら、表示中メトリクスのリセット後にバブルを復活させる
    private func scheduleRevivalIfNeeded() {
        revivalTask?.cancel()
        guard settings.reviveBubble,
              let resets = bubbleUsageWindow?.resetsAt,
              resets.timeIntervalSinceNow > 0 else { return }
        let delay = resets.timeIntervalSinceNow + 90
        revivalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            guard self.state.mode == .attached, self.panel?.isVisible != true else { return }
            await self.usageService.refresh()
            guard (self.bubbleUsageWindow?.utilization ?? 0) < 100 else { return }
            self.showBubble(at: self.lastBubbleCenter ?? self.defaultBubblePoint(), poppingIn: true)
        }
    }

    private func showPopBurst(centeredOn center: NSPoint) {
        let size: CGFloat = 240
        let w = NSWindow(
            contentRect: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: PopBurstView())
        w.orderFrontRegardless()
        popWindow = w
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.0))
            self?.popWindow?.orderOut(nil)
            self?.popWindow = nil
        }
    }

    // MARK: - 共通

    /// hideのフェード完了後にorderOutする前に、別のshowが走っていたらキャンセルするための世代カウンタ
    private var hideGeneration = 0

    private func cancelPendingHide() {
        hideGeneration += 1
    }

    func hide() {
        removeDismissMonitors()
        guard let p = panel, p.isVisible else {
            if isBubbleChrome { resetChromeAfterHide() }
            return
        }
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideGeneration == generation else { return }
                p.orderOut(nil)
                p.alphaValue = 1
                self.assemblyView?.alphaValue = 1
                self.resetChromeAfterHide()
            }
        })
    }

    private func animateFrame(to rect: NSRect, completion: (() -> Void)? = nil) {
        guard let p = panel else { return }
        isProgrammaticMove = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            // 少しオーバーシュートさせて弾力を出す
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.12)
            p.animator().setFrame(rect, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.isProgrammaticMove = false
                completion?()
            }
        })
    }

    // MARK: - ドラッグ検知（tear-off）

    func windowDidMove(_ notification: Notification) {
        guard let p = panel, p.isVisible, !isProgrammaticMove else { return }
        switch state.mode {
        case .attached:
            // 引き剥がしたらフローティングパネルになる（バブルは🫧ボタンからのみ）
            let o = p.frame.origin
            if hypot(o.x - attachedOrigin.x, o.y - attachedOrigin.y) > detachThreshold {
                detachToFloating()
            }
        case .bubble, .floating:
            break
        }
    }

    /// tear-off: メニューバーから引き剥がしてフローティングパネルにする（ぷるんっ付き）
    private func detachToFloating() {
        guard state.mode == .attached, let p = panel else { return }
        state.mode = .floating
        state.detachBounce += 1
        removeDismissMonitors()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        p.level = .floating
        p.isMovableByWindowBackground = true
    }

    /// バブルをメニューバーのステータスアイテム付近へドラッグしたら吸い込まれて戻る
    private func snapBackToMenuBar(buttonFrame: NSRect) {
        guard state.mode == .bubble, isBubbleChrome,
              let p = panel, let assembly = assemblyView else { return }
        state.mode = .attached
        stopDrifting()
        stopMouseTracking()
        p.ignoresMouseEvents = false
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)

        // ボタン位置へ吸い込まれる（ウィンドウは固定、アセンブリを縮小+フェード）
        let targetOnScreen = NSRect(x: buttonFrame.midX - 6, y: buttonFrame.minY - 10, width: 12, height: 12)
        let targetInWindow = p.convertFromScreen(targetOnScreen)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            assembly.animator().frame = targetInWindow
            assembly.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel else { return }
                p.orderOut(nil)
                self.assemblyView?.alphaValue = 1
                self.resetChromeAfterHide()
            }
        })
    }

    // MARK: - attached時の外側クリックで閉じる

    private func installDismissMonitors() {
        removeDismissMonitors()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hideIfAttached() }
        }) {
            clickMonitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, let p = self.panel, event.window !== p {
                    self.hideIfAttached()
                }
            }
            return event
        }) {
            clickMonitors.append(m)
        }
    }

    private func hideIfAttached() {
        if state.mode == .attached { hide() }
    }

    private func removeDismissMonitors() {
        clickMonitors.forEach { NSEvent.removeMonitor($0) }
        clickMonitors.removeAll()
    }
}
