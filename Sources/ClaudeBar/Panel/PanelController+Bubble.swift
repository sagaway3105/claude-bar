import AppKit
import QuartzCore
import SwiftUI

/// バブル（浮遊モード）固有の挙動。
///
/// バブルは100ptの小さな透明ウィンドウで、その中のアセンブリ（ガラス+内容76pt）だけを
/// レンダーサーバ側の無限アニメーションで漂わせる（ウィンドウ自体は動かさないので滑らか）。
/// 操作はAppKitのローカルモニタで判定: クリック=展開 / ドラッグ=ウィンドウ移動 /
/// メニューバー付近で放す=吸着して戻る。ホバーで「ポヨン」。
extension PanelController {

    // MARK: - バブル用クローム（小さな固定ウィンドウ + 中で漂うアセンブリ）

    func enterBubbleChrome(centeredAt center: NSPoint) {
        guard let p = panel, let assembly = assemblyView else { return }
        isBubbleChrome = true
        containerView?.pinsChildrenToBounds = false
        let size = bubbleWindowSize
        isProgrammaticMove = true
        p.setFrame(
            NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size),
            display: true
        )
        isProgrammaticMove = false
        p.hasShadow = false // アセンブリ移動のたびに影を再計算させない
        p.ignoresMouseEvents = false

        assembly.autoresizingMask = []
        let margin = (size - bubbleDiameter) / 2
        floatAnchor = NSPoint(x: margin, y: margin)
        wasHoveringBubble = false
        assembly.frame = NSRect(origin: floatAnchor, size: NSSize(width: bubbleDiameter, height: bubbleDiameter))
        contentHosting?.frame = assembly.bounds

        // ドラッグ時のウィンドウ原点の可動域（メニューバーとDockを避けた可視領域）
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? p.screen ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            floatBounds = NSRect(
                x: vf.minX, y: vf.minY,
                width: max(0, vf.width - size), height: max(0, vf.height - size)
            )
        }
        startMouseTracking()
        installBubbleMouseMonitor()
        // アクセサリアプリはApp Napでタイマーが間引かれるため、バブル表示中は抑止する
        if napActivity == nil {
            napActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated], reason: "Bubble float animation"
            )
        }
    }

    /// パネルモードへ戻す: ウィンドウをアセンブリにぴったり合わせ、autoresizeを復帰
    func exitBubbleChrome() {
        guard isBubbleChrome, let p = panel, let assembly = assemblyView, let container = containerView else { return }
        stopFloating()
        isBubbleChrome = false
        container.pinsChildrenToBounds = true
        stopMouseTracking()
        removeBubbleMouseMonitor()
        let assemblyOnScreen = p.convertToScreen(assembly.frame)
        isProgrammaticMove = true
        p.setFrame(assemblyOnScreen, display: false)
        isProgrammaticMove = false
        p.hasShadow = true
        assembly.autoresizingMask = []
        assembly.frame = container.bounds
        syncPanelChromeFrames()
    }

    /// 非表示のままクロームを解除（pop後・吸着後など）
    func resetChromeAfterHide() {
        guard isBubbleChrome, let p = panel, let assembly = assemblyView, let container = containerView else { return }
        stopFloating()
        isBubbleChrome = false
        container.pinsChildrenToBounds = true
        stopMouseTracking()
        removeBubbleMouseMonitor()
        isProgrammaticMove = true
        p.setFrame(
            NSRect(origin: p.frame.origin, size: NSSize(width: panelWidth, height: panelWindowHeight)),
            display: false
        )
        isProgrammaticMove = false
        p.hasShadow = true
        assembly.autoresizingMask = []
        assembly.frame = container.bounds
        assembly.alphaValue = 1
        syncPanelChromeFrames()
    }

    // MARK: - カーソル追跡（ホバーのポヨン）

    func startMouseTracking() {
        stopMouseTracking()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTrackTimer = timer
    }

    private func trackMouse() {
        guard isBubbleChrome else { return }
        guard let bubbleOnScreen = assemblyScreenFrame?.insetBy(dx: -6, dy: -6) else { return }
        let inside = bubbleOnScreen.contains(NSEvent.mouseLocation)
        if inside, !wasHoveringBubble, !dragActive,
           Date().timeIntervalSince(lastHoverBounceAt) > 0.6 {
            lastHoverBounceAt = Date()
            bounceAssembly() // ポヨン
        }
        wasHoveringBubble = inside
    }

    func stopMouseTracking() {
        mouseTrackTimer?.invalidate()
        mouseTrackTimer = nil
        if let activity = napActivity {
            ProcessInfo.processInfo.endActivity(activity)
            napActivity = nil
        }
    }

    // MARK: - モード遷移

    /// 🫧ボタン経由（パネル表示中からの変形）
    func becomeBubble(at point: NSPoint) {
        guard state.mode != .bubble, let p = panel else { return }
        // 直前の外側クリック等でパネルが閉じ（かけ）ていたら、出現アニメーション経路へ
        guard p.isVisible else {
            showBubble(at: point, poppingIn: true)
            return
        }
        cancelPendingHide()
        revivalTask?.cancel()
        state.mode = .bubble
        removeDismissMonitors()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)

        // hideのフェードが進行中でも確実に見える状態へ戻す（進行中のalphaアニメーションを上書き）
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            p.animator().alphaValue = 1
        }
        p.orderFrontRegardless()
        p.level = .floating
        p.isMovableByWindowBackground = false

        // まずウィンドウごとバブルサイズへ縮め、完了後にバブル用クロームへ差し替える（見た目は不変）
        let tight = NSRect(
            x: point.x - bubbleDiameter / 2, y: point.y - bubbleDiameter / 2,
            width: bubbleDiameter, height: bubbleDiameter
        )
        animateFrame(to: tight) { [weak self] in
            guard let self, self.state.mode == .bubble, let p = self.panel else { return }
            self.enterBubbleChrome(centeredAt: NSPoint(x: p.frame.midX, y: p.frame.midY))
            self.startFloating()
            self.bounceAssembly() // ぷるんっ
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
        // 進行中のalphaフェードがあっても確実に見える状態へ
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            p.animator().alphaValue = 1
        }
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
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.34
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.18)
                assembly.animator().frame = target
                assembly.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.startFloating() }
            })
        } else {
            p.orderFrontRegardless()
            startFloating()
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
        p.isMovableByWindowBackground = true

        DispatchQueue.main.async { [weak self] in
            guard let self, let p = self.panel else { return }
            self.lastPanelSize = NSSize(width: self.panelWidth, height: self.measuredPanelHeight())
            let size = NSSize(width: self.panelWidth, height: self.panelWindowHeight)

            let bubbleFrame = p.frame
            var origin = NSPoint(
                x: bubbleFrame.midX - size.width / 2,
                y: bubbleFrame.maxY - size.height
            )
            if let screen = p.screen ?? NSScreen.main {
                let vf = screen.visibleFrame
                origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
                // 内容は上詰めなので、内容部分が画面内に収まるようにクランプ
                origin.y = min(max(origin.y, vf.minY + 8 - (size.height - self.lastPanelSize.height)), vf.maxY - size.height - 8)
            }
            self.animateFrame(to: NSRect(origin: origin, size: size))
        }
    }

    // MARK: - 浮遊（アンカー周辺・無限リピートの加算アニメーション）

    /// 周期の異なる正弦波（easeInEaseOutのautoreverse）を加算合成してその場でゆったり漂わせる。
    /// レンダーサーバ側で無限に補間されるため、繋ぎ目もフレーム落ちも存在しない。
    func startFloating() {
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

    func stopFloating() {
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
    }

    // MARK: - バブルの操作（AppKitレベルのマウス処理: クリック=展開 / ドラッグ=ウィンドウ移動）

    func installBubbleMouseMonitor() {
        removeBubbleMouseMonitor()
        bubbleMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleBubbleMouse(event) ?? false }
            return consumed ? nil : event
        }
    }

    func removeBubbleMouseMonitor() {
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
            dragStartAnchor = p.frame.origin // バブルではウィンドウ自体を動かす
            return true
        case .leftMouseDragged:
            guard dragActive, let start = dragStartAnchor else { return false }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - dragStartMouse.x
            let dy = mouse.y - dragStartMouse.y
            if hypot(dx, dy) > 3 { dragMoved = true }
            var origin = NSPoint(x: start.x + dx, y: start.y + dy)
            origin.x = min(max(origin.x, floatBounds.minX), floatBounds.maxX)
            origin.y = min(max(origin.y, floatBounds.minY), floatBounds.maxY)
            isProgrammaticMove = true
            p.setFrameOrigin(origin)
            isProgrammaticMove = false
            return true
        case .leftMouseUp:
            guard dragActive else { return false }
            dragActive = false
            isDraggingBubble = false
            dragStartAnchor = nil
            if !dragMoved {
                registerBubbleTap() // クリック = ポヨン、連打で破裂!
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

    /// バブルのクリック遊び: 1回目ポヨン、2回目強めのポヨン、3連打で破裂💥
    private func registerBubbleTap() {
        bubbleTapCount += 1
        bubbleTapResetTask?.cancel()

        if bubbleTapCount >= 3 {
            bubbleTapCount = 0
            popBubble()
            return
        }
        bounceAssembly(intensity: bubbleTapCount == 1 ? 1.0 : 1.6)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        bubbleTapResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            self?.bubbleTapCount = 0
        }
    }

    // MARK: - 割れる（100%）と復活

    func popBubble() {
        guard state.mode == .bubble, !isPopping, let assembly = assemblyView else { return }
        isPopping = true
        stopFloating()
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

    /// バブルをメニューバーのステータスアイテム付近へドラッグしたら吸い込まれて戻る
    private func snapBackToMenuBar(buttonFrame: NSRect) {
        guard state.mode == .bubble, isBubbleChrome, let p = panel else { return }
        state.mode = .attached
        exitBubbleChrome() // ウィンドウがバブルにぴったり合った状態になる
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)

        let target = NSRect(x: buttonFrame.midX - 6, y: buttonFrame.minY - 10, width: 12, height: 12)
        isProgrammaticMove = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().setFrame(target, display: true)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel else { return }
                self.isProgrammaticMove = false
                p.orderOut(nil)
                p.alphaValue = 1
            }
        })
    }
}
