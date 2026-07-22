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

    // ウィンドウ構成: panel > container(クリック透過) > assembly(動かす単位) > hosting
    // ガラスはSwiftUI側の .glassEffect が内容にピッタリ描く（AppKitのレイアウト問題を排除）
    var panel: NSPanel?
    var containerView: PassthroughContainerView?
    var assemblyView: NSView?
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

    // バブルのマウス操作（クリック=ポヨン、連打=破裂 / ドラッグ=移動）
    var bubbleMouseMonitor: Any?
    var dragActive = false
    var dragMoved = false
    var dragStartMouse = NSPoint.zero
    var bubbleTapCount = 0
    var bubbleTapResetTask: Task<Void, Never>?

    // レイアウト定数
    let panelWidth: CGFloat = 300
    let panelWindowHeight: CGFloat = 460 // 固定（内容はSwiftUIが上詰めで描き、余りは完全透明）
    let bubbleDiameter: CGFloat = 76
    let bubbleWindowSize: CGFloat = 150 // 最大バブル(76*1.4)+浮遊・伸縮マージン
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

    /// 使用量に応じたバブルの拡大率: 10%ごとに+4%、100%で1.4倍（風船のように膨らむ）
    static func bubbleScaleFactor(for utilization: Double) -> CGFloat {
        1 + 0.04 * CGFloat((min(max(utilization, 0), 100) / 10).rounded(.down))
    }

    /// 現在の使用量に応じたバブルの直径
    var currentBubbleDiameter: CGFloat {
        bubbleDiameter * Self.bubbleScaleFactor(for: bubbleUsageWindow?.utilization ?? 0)
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
            } else if state.mode == .bubble {
                // バブル表示中: メニューバーを押せば通常のパネルに戻る
                showAttached(relativeTo: button)
            } else {
                // フローティング表示中: メニューバーを押せば引き剥がし前（attached）に戻る
                showAttached(relativeTo: button)
            }
            return
        }
        showAttached(relativeTo: button)
    }

    // MARK: - ウィンドウ生成

    /// AppKitの「ウィンドウ上端はメニューバーの下まで」制約を無効化したパネル。
    /// 位置は全て自前でクランプするため（バブルはメニューバーを覆う高さまで行ける）
    private final class UnconstrainedPanel: NSPanel {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }

    func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let p = UnconstrainedPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelWindowHeight),
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

        let container = PassthroughContainerView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelWindowHeight))
        container.wantsLayer = true

        // フレームは全て手動管理（autoresizing/Auto Layoutのタイミング問題を排除）
        let assembly = NSView(frame: container.bounds)
        assembly.wantsLayer = true
        assembly.autoresizingMask = []

        let hosting = NSHostingView(
            rootView: PanelRootView(state: state, settings: settings, actions: uiActions)
        )
        // SwiftUI側の固定サイズが必須制約としてAuto Layoutへ伝わり
        // ウィンドウが内容サイズへ勝手に収縮するため、サイズ要求を無効化する
        hosting.sizingOptions = []
        hosting.frame = assembly.bounds
        hosting.autoresizingMask = []

        assembly.addSubview(hosting)
        container.addSubview(assembly)
        p.contentView = container

        panel = p
        containerView = container
        assemblyView = assembly
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
        clearCloseAnimations()
        exitBubbleChrome()
        state.mode = .attached
        p.isMovableByWindowBackground = false
        p.level = .popUpMenu
        assemblyView?.alphaValue = 1
        p.alphaValue = 1
        state.menuHighlighted = true // 押した瞬間に点灯（Apple流）

        // 位置決め（同期・固定サイズ）
        guard let buttonWindow = button.window else { return }
        let screen = buttonWindow.screen ?? NSScreen.main
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonRect.midX - panelWidth / 2
        if let screen {
            x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - panelWidth - 8)
        }
        let y = buttonRect.minY - panelWindowHeight - 6
        isProgrammaticMove = true
        p.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelWindowHeight), display: false)
        isProgrammaticMove = false
        syncPanelChromeFrames()
        attachedOrigin = NSPoint(x: x, y: y)

        // 最初のフレームを完成させてから即時表示（純正メニューと同じ歯切れ）
        contentHosting?.layoutSubtreeIfNeeded()
        p.displayIfNeeded()
        p.orderFrontRegardless()
        playOpenAnimation()
        installDismissMonitors()
        // フルスクリーンアプリ上でもメニューバーが維持される（純正メニューと同じ振る舞い）
        DistributedNotificationCenter.default().post(
            name: .init("com.apple.HIToolbox.beginMenuTrackingNotification"), object: nil
        )

        // 高さ実測（透明帯クリック判定用）と更新は表示後に回す
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastPanelSize = NSSize(width: self.panelWidth, height: self.measuredPanelHeight())
            self.usageService.refreshIfStale(olderThan: 45)
        }
    }

    /// コンテンツの実高さの記録（ウィンドウは固定サイズなのでリサイズはしない。
    /// 下部の透明帯クリック判定に使う）
    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 100 else { return }
        lastPanelSize = NSSize(width: panelWidth, height: height)
    }

    // MARK: - tear-off（引き剥がし → フローティングパネル）

    /// 上端中央（ステータスアイテム側）基準のスケール変換
    private func topAnchoredScale(_ scale: CGFloat) -> CATransform3D {
        guard let assembly = assemblyView else { return CATransform3DIdentity }
        let w = assembly.bounds.width
        let h = assembly.bounds.height
        var m = CATransform3DMakeTranslation(w / 2 * (1 - scale), h * (1 - scale), 0)
        m = CATransform3DScale(m, scale, scale, 1)
        return m
    }

    /// 展開アニメーション: ステータスアイテムを支点に上端中央から生える（純正Tahoeメニュー風）。
    /// 使い捨てのCAアニメーション（モデル値不変・完了時自動除去）なので途中で閉じても競合しない。
    private func playOpenAnimation() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = assemblyView?.layer else { return }
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: topAnchoredScale(0.97))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = 0.18
        grow.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.13
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        layer.add(grow, forKey: "open-grow")
        layer.add(fade, forKey: "open-fade")
    }

    /// クローズアニメーション（fillForwards）の残骸を掃除する（show側で必ず呼ぶ）
    func clearCloseAnimations() {
        assemblyView?.layer?.removeAnimation(forKey: "close-shrink")
        assemblyView?.layer?.removeAnimation(forKey: "close-fade")
    }

    /// パネル内容の必要高さを同期的に実測する（SwiftUIの報告待ちに依存しない）
    func measuredPanelHeight() -> CGFloat {
        let controller = NSHostingController(
            rootView: UsagePanelView(state: state, settings: settings, actions: uiActions)
        )
        let size = controller.sizeThatFits(in: NSSize(width: panelWidth, height: 2000))
        return max(200, min(size.height, 800))
    }

    /// パネルモードでは assembly/glass/hosting をコンテナへ明示同期する。
    /// リサイズ通知中はautoresize処理と競合するため、次のランループで行う。
    func windowDidResize(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.syncPanelChromeFrames()
        }
    }

    func syncPanelChromeFrames() {
        guard !isBubbleChrome, let container = containerView else { return }
        assemblyView?.frame = container.bounds
        contentHosting?.frame = container.bounds
    }

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
        bounceAssembly() // ぷるんっ
        removeDismissMonitors()
        state.menuHighlighted = false
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
        state.menuHighlighted = false
        cancelPendingHide() // 過去の遅延orderOutを無効化
        DistributedNotificationCenter.default().post(
            name: .init("com.apple.HIToolbox.endMenuTrackingNotification"), object: nil
        )
        guard let p = panel else { return }

        // バブル演出後や「視差を減らす」時は即時クローズ
        if isBubbleChrome || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !p.isVisible {
            p.orderOut(nil)
            p.alphaValue = 1
            assemblyView?.alphaValue = 1
            resetChromeAfterHide()
            return
        }

        // 純正風クローズ: アイテム側へわずかに縮みながら素早くフェード。
        // fillForwardsで終端を保持し、世代ガード付きの遅延orderOutで確定させる
        // （show側は cancelPendingHide + clearCloseAnimations で必ず巻き戻せる）
        hideGeneration += 1
        let generation = hideGeneration
        if let layer = assemblyView?.layer {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            shrink.toValue = NSValue(caTransform3D: topAnchoredScale(0.97))
            shrink.duration = 0.14
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            fade.duration = 0.12
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false

            layer.add(shrink, forKey: "close-shrink")
            layer.add(fade, forKey: "close-fade")
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.15))
            guard let self, self.hideGeneration == generation, let p = self.panel else { return }
            self.clearCloseAnimations()
            p.orderOut(nil)
            p.alphaValue = 1
            self.assemblyView?.alphaValue = 1
            self.resetChromeAfterHide()
        }
    }

    /// 「ぷるんっ/ポヨン」— アセンブリ（ガラスごと）を中心基準でスクワッシュ&ストレッチ。
    /// SwiftUI側でコンテンツを拡大するとガラスの円形マスクで切れるため、レイヤー変形で行う。
    func bounceAssembly(intensity: CGFloat = 1) {
        guard let assembly = assemblyView, let layer = assembly.layer else { return }
        let w = assembly.bounds.width
        let h = assembly.bounds.height
        let k = intensity
        let animation = CAKeyframeAnimation(keyPath: "transform")
        if isBubbleChrome {
            // バブル: ウィンドウに余白があるため中心基準で素直に膨らめる
            let cx = w / 2
            let cy = h / 2
            func scaled(_ sx: CGFloat, _ sy: CGFloat) -> CATransform3D {
                var m = CATransform3DMakeTranslation(cx * (1 - sx), cy * (1 - sy), 0)
                m = CATransform3DScale(m, sx, sy, 1)
                return m
            }
            animation.values = [
                CATransform3DIdentity,
                scaled(1 + 0.12 * k, 1 - 0.12 * k),
                scaled(1 - 0.06 * k, 1 + 0.06 * k),
                scaled(1 + 0.03 * k, 1 - 0.02 * k),
                CATransform3DIdentity,
            ].map { NSValue(caTransform3D: $0) }
        } else {
            // パネル: コンテンツは横幅ぴったり・上端いっぱいのため、拡大方向は
            // ウィンドウ境界でクリップされる（上下欠けの原因）。
            // 縦は上端アンカーで「下の透明帯ぶんだけ」伸ばし、横は1.0以下に留める
            let contentH = max(1, lastPanelSize.height)
            let slackRatio = max(0, h - contentH - 2) / contentH
            let stretch = 1 + min(0.05 * k, slackRatio)
            func scaled(_ sx: CGFloat, _ sy: CGFloat) -> CATransform3D {
                // 横は中央基準・縦は上端(y=h)基準
                var m = CATransform3DMakeTranslation(w / 2 * (1 - sx), h * (1 - sy), 0)
                m = CATransform3DScale(m, sx, sy, 1)
                return m
            }
            animation.values = [
                CATransform3DIdentity,
                scaled(1 - 0.05 * k, stretch), // 引き剥がされて下へぷるん
                scaled(1, 1 - 0.045 * k), // 反動で縮む
                scaled(1 - 0.015 * k, 1 + min(0.012 * k, slackRatio)),
                CATransform3DIdentity,
            ].map { NSValue(caTransform3D: $0) }
        }
        animation.keyTimes = [0, 0.22, 0.5, 0.75, 1]
        animation.duration = 0.45
        animation.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4
        )
        layer.add(animation, forKey: "poyon")
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
                guard let self, let p = self.panel else { return }
                // ステータスアイコン上のクリックはtoggle側で開閉するので、ここでは閉じない
                if let bf = self.statusButtonFrame?(), let w = event.window {
                    let screenPoint = w.convertPoint(toScreen: event.locationInWindow)
                    if bf.insetBy(dx: -2, dy: -2).contains(screenPoint) { return }
                }
                if event.window !== p {
                    self.hideIfAttached()
                } else if self.state.mode == .attached,
                          event.locationInWindow.y < p.frame.height - self.lastPanelSize.height {
                    // パネル下の透明帯をクリックした場合も閉じる
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
