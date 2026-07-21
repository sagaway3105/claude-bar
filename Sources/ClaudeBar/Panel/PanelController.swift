import AppKit
import QuartzCore
import SwiftUI

/// パネル/バブルのウィンドウ制御（コア: ウィンドウ生成・attached・tear-off・表示/非表示）。
/// バブル固有の挙動は PanelController+Bubble.swift にある。
///
/// モード:
/// - attached: メニューバー直下（外側クリックで閉じる）
/// - floating: 引き剥がした（またはバブルから展開した）フローティングパネル
/// - bubble:   その場でゆったり浮遊する常時最前面のバブル（🫧ボタン/右クリックから）
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let state: AppState
    let usageService: UsageService
    let settings: SettingsStore

    /// StatusItemControllerから注入される（吸着判定・デフォルト位置用）
    var statusButtonFrame: (() -> NSRect?)?
    var onOpenSettings: (() -> Void)?

    private(set) lazy var uiActions: PanelActions = makeActions()

    // ウィンドウ構成: panel > container(クリック透過) > assembly(動かす単位) > glass > hosting
    var panel: NSPanel?
    var containerView: PassthroughContainerView?
    var assemblyView: NSView?
    var glassView: NSGlassEffectView?
    var contentHosting: NSHostingView<PanelRootView>?
    var popWindow: NSWindow?

    var attachedOrigin = NSPoint.zero
    var isProgrammaticMove = false
    var isPopping = false
    var isBubbleChrome = false
    var lastPanelSize = NSSize(width: 240, height: 380)
    var lastBubbleCenter: NSPoint?
    var revivalTask: Task<Void, Never>?
    private var clickMonitors: [Any] = []

    // 浮遊状態（アンカー周辺を、無限リピートの加算アニメーションで漂う）
    var floatAnchor = NSPoint.zero  // アセンブリ原点（ウィンドウ座標）
    var floatBounds = NSRect.zero   // ドラッグ可能範囲（ウィンドウ座標）
    var dragStartAnchor: NSPoint?
    var isDraggingBubble = false
    var wasHoveringBubble = false
    var lastHoverBounceAt = Date.distantPast
    var mouseTrackTimer: Timer?
    var napActivity: NSObjectProtocol?

    // バブルのマウス操作（クリック=展開 / ドラッグ=移動）
    var bubbleMouseMonitor: Any?
    var dragActive = false
    var dragMoved = false
    var dragStartMouse = NSPoint.zero

    // レイアウト定数
    let panelWidth: CGFloat = 240
    let bubbleDiameter: CGFloat = 76
    let panelCornerRadius: CGFloat = 24
    let detachThreshold: CGFloat = 30
    let snapMargin: CGFloat = 60

    init(state: AppState, usageService: UsageService, settings: SettingsStore) {
        self.state = state
        self.usageService = usageService
        self.settings = settings
        super.init()
    }

    // MARK: - 共有ヘルパー

    /// バブルが表示している使用量ウィンドウ（設定で選択）
    var bubbleUsageWindow: UsageWindow? {
        state.usage?.window(for: settings.bubbleMetric)
    }

    /// アセンブリの現在のスクリーン座標（アニメーション中はpresentation layerが真実）
    var assemblyScreenFrame: NSRect? {
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

    func ensurePanel() -> NSPanel {
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
            login: { LoginHelper.openLoginTerminal() },
            contentHeightChanged: { [weak self] height in self?.contentHeightChanged(height) }
        )
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

    // MARK: - tear-off（引き剥がし → フローティングパネル）

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

    // MARK: - 表示/非表示

    /// hideのフェード完了後にorderOutする前に、別のshowが走っていたらキャンセルするための世代カウンタ
    private var hideGeneration = 0

    func cancelPendingHide() {
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

    func animateFrame(to rect: NSRect, completion: (() -> Void)? = nil) {
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

    // MARK: - attached時の外側クリックで閉じる

    func installDismissMonitors() {
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

    func removeDismissMonitors() {
        clickMonitors.forEach { NSEvent.removeMonitor($0) }
        clickMonitors.removeAll()
    }

    // MARK: - デバッグ用

    var debugPanelFrame: NSRect? {
        if isBubbleChrome { return assemblyScreenFrame }
        return panel?.frame
    }

    var debugPanelVisible: Bool { panel?.isVisible ?? false }
}
