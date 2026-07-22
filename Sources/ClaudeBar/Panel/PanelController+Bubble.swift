import AppKit
import QuartzCore
import SwiftUI

/// バブル（浮遊モード）固有の挙動。
///
/// バブルは専用の150pt透明ウィンドウで、その中のアセンブリ（ガラス+内容76-106pt）だけを
/// レンダーサーバ側の無限アニメーションで漂わせる（ウィンドウ自体は動かさないので滑らか）。
/// パネルとは独立したウィンドウなので、パネルを開いたままバブルを共存できる。
/// 操作はAppKitのローカルモニタで判定: クリック=ポヨン(連打で破裂) / ドラッグ=ウィンドウ移動 /
/// メニューバー付近で放す=吸着して消える。ホバーで「ポヨン」。
extension PanelController {

    // MARK: - ウィンドウ生成

    func ensureBubblePanel() -> NSPanel {
        if let bubblePanel { return bubblePanel }

        let size = bubbleWindowSize
        // 影なし: アセンブリ移動のたびに影を再計算させない
        let p = makeOverlayPanel(size: NSSize(width: size, height: size), level: .floating, hasShadow: false)

        let container = PassthroughContainerView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        container.wantsLayer = true
        container.pinsChildrenToBounds = false // アセンブリは中で自由に漂う

        let assembly = NSView(frame: container.bounds)
        assembly.wantsLayer = true
        assembly.autoresizingMask = []

        let hosting = NSHostingView(
            rootView: BubbleRootView(state: state, settings: settings, actions: uiActions)
        )
        hosting.sizingOptions = [] // SwiftUIの固定サイズを必須制約にしない（ウィンドウ収縮防止）
        hosting.frame = assembly.bounds
        hosting.autoresizingMask = []

        assembly.addSubview(hosting)
        container.addSubview(assembly)
        p.contentView = container

        bubblePanel = p
        bubbleContainer = container
        bubbleAssembly = assembly
        bubbleHosting = hosting
        return p
    }

    // MARK: - トグル（🫧ボタン）

    /// 🫧ボタン: OFF→ぽわんっと出現 / ON→消える。パネルはそのまま
    func toggleBubble() {
        if state.bubbleActive {
            dismissBubble()
            return
        }
        var point = defaultBubblePoint()
        if let pf = panel, pf.isVisible {
            // パネルの左横に出す（パネルと重ならないように）
            point = NSPoint(x: pf.frame.minX - bubbleWindowSize / 2 + 24, y: pf.frame.midY)
            if let vf = (pf.screen ?? NSScreen.main)?.visibleFrame {
                point.x = max(point.x, vf.minX + 60)
                point.y = min(max(point.y, vf.minY + 60), vf.maxY - 60)
            }
        }
        showBubble(at: point, poppingIn: true)
    }

    /// バブルを表示（ONにする）。復活・右クリックメニュー・デバッグからも使う
    func showBubble(at point: NSPoint, poppingIn: Bool = false) {
        let p = ensureBubblePanel()
        bubbleHideGeneration += 1 // 進行中の遅延orderOutを無効化
        revivalTask?.cancel()
        isPopping = false
        state.bubbleActive = true

        let size = bubbleWindowSize
        p.setFrame(
            NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
            display: true
        )
        guard let assembly = bubbleAssembly else { return }
        assembly.layer?.removeAllAnimations()
        let diameter = currentBubbleDiameter
        let margin = (size - diameter) / 2
        wasHoveringBubble = false
        assembly.frame = NSRect(x: margin, y: margin, width: diameter, height: diameter)
        assembly.alphaValue = 1
        bubbleHosting?.frame = assembly.bounds

        updateFloatBounds(around: point)
        startMouseTracking()
        installBubbleMouseMonitor()
        // アクセサリアプリはApp Napでタイマーが間引かれるため、バブル表示中は抑止する
        if napActivity == nil {
            napActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated], reason: "Bubble float animation"
            )
        }
        // 文字色の動的切り替えは設定でONの場合のみ（権限要求は設定トグル側で行う）
        state.bubbleBackdropIsDark = nil

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

    /// バブルを非表示（OFFにする）。アクティブな🫧ボタン押下時
    func dismissBubble() {
        state.bubbleActive = false
        revivalTask?.cancel()
        guard let p = bubblePanel, p.isVisible, let assembly = bubbleAssembly else { return }
        stopFloating()
        stopMouseTracking()
        removeBubbleMouseMonitor()
        bubbleHideGeneration += 1
        let generation = bubbleHideGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            assembly.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.bubbleHideGeneration == generation else { return }
                self.bubblePanel?.orderOut(nil)
                self.bubbleAssembly?.alphaValue = 1
            }
        })
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

    /// バブルの右クリック「パネルに展開」: バブルはそのまま、その場にフローティングパネルを開く
    func expandFromBubble() {
        let anchorFrame = bubbleScreenFrame ?? bubblePanel?.frame
        let p = ensurePanel()
        cancelPendingHide()
        clearCloseAnimations()
        state.mode = .floating
        state.menuHighlighted = false
        p.level = .floating
        p.isMovableByWindowBackground = true

        lastPanelSize = NSSize(width: panelWidth, height: measuredPanelHeight())
        let size = NSSize(width: panelWidth, height: panelWindowHeight)
        var origin = NSPoint(x: 300, y: 300)
        if let anchor = anchorFrame {
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY - size.height)
        }
        if let screen = bubblePanel?.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            // 内容は上詰めなので、内容部分が画面内に収まるようにクランプ
            origin.y = min(max(origin.y, vf.minY + 8 - (size.height - lastPanelSize.height)), vf.maxY - size.height - 8)
        }
        isProgrammaticMove = true
        p.setFrame(NSRect(origin: origin, size: size), display: false)
        isProgrammaticMove = false
        syncPanelChromeFrames()
        contentHosting?.layoutSubtreeIfNeeded()
        p.displayIfNeeded()
        p.orderFrontRegardless()
        playOpenAnimation()
    }

    // MARK: - 可動域

    /// ドラッグ時のウィンドウ原点の可動域を更新する。
    /// ウィンドウ(150pt)ではなく「見えているバブルの縁」が画面の縁に届く基準:
    /// 左右・下は画面端（下はDockの上端）に接するまで、上はメニューバーを覆えるまで。
    func updateFloatBounds(around point: NSPoint) {
        let size = bubbleWindowSize
        let margin = (size - currentBubbleDiameter) / 2
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? bubblePanel?.screen ?? NSScreen.main
        guard let vf = screen?.visibleFrame, let sf = screen?.frame else { return }
        floatBounds = NSRect(
            x: sf.minX - margin,
            y: vf.minY - margin,
            width: max(0, sf.width - size + margin * 2),
            height: max(0, (sf.maxY - size + margin) - (vf.minY - margin))
        )
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
        guard state.bubbleActive else { return }
        growBubbleIfNeeded()
        sampleBackdropIfNeeded()
        guard let bubbleOnScreen = bubbleScreenFrame?.insetBy(dx: -6, dy: -6) else { return }
        let inside = bubbleOnScreen.contains(NSEvent.mouseLocation)
        if inside, !wasHoveringBubble, !dragActive,
           Date().timeIntervalSince(lastHoverBounceAt) > 0.6 {
            lastHoverBounceAt = Date()
            bounceBubble() // ポヨン
        }
        wasHoveringBubble = inside
    }

    /// 使用量が10%刻みを跨いだらバブルをぷにっと成長させる
    private func growBubbleIfNeeded() {
        guard !dragActive, !isPopping,
              let assembly = bubbleAssembly, let hosting = bubbleHosting else { return }
        let desired = currentBubbleDiameter
        guard abs(assembly.frame.width - desired) > 0.5 else { return }

        let center = NSPoint(x: assembly.frame.midX, y: assembly.frame.midY)
        let target = NSRect(
            x: center.x - desired / 2, y: center.y - desired / 2,
            width: desired, height: desired
        )
        hosting.frame = NSRect(origin: .zero, size: target.size)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.25)
            assembly.animator().frame = target
        }
        // 直径が変わるとマージンも変わるため可動域を取り直す
        if let w = bubblePanel {
            updateFloatBounds(around: NSPoint(x: w.frame.midX, y: w.frame.midY))
        }
    }

    func stopMouseTracking() {
        mouseTrackTimer?.invalidate()
        mouseTrackTimer = nil
        if let activity = napActivity {
            ProcessInfo.processInfo.endActivity(activity)
            napActivity = nil
        }
    }

    /// 背後の画面輝度を約1秒間隔でサンプリングし、バブルの文字色（白/黒）を切り替える。
    /// 設定でOFF・画面収録の権限が無い間は何もしない（従来の固定色のまま）
    private func sampleBackdropIfNeeded() {
        guard ProcessInfo.processInfo.environment["CLAUDEBAR_FAKE"] == nil else { return } // デバッグはbackdrop:コマンドで強制
        guard settings.adaptiveBubbleTextColor else {
            if state.bubbleBackdropIsDark != nil { state.bubbleBackdropIsDark = nil }
            return
        }
        guard BackdropSampler.hasPermission,
              state.bubbleActive, !isPopping, !backdropSampleInFlight,
              Date().timeIntervalSince(lastBackdropSampleAt) > 1.0,
              let frame = bubbleScreenFrame else { return }
        lastBackdropSampleAt = Date()
        backdropSampleInFlight = true
        Task { [weak self] in
            let luminance = await BackdropSampler.averageLuminance(of: frame.insetBy(dx: 8, dy: 8))
            guard let self else { return }
            self.backdropSampleInFlight = false
            guard let luminance else { return } // 失敗時は前回の判定を維持
            // ヒステリシス: 境界付近での白黒チラつきを防ぐ
            if luminance < 0.42 {
                self.state.bubbleBackdropIsDark = true
            } else if luminance > 0.5 {
                self.state.bubbleBackdropIsDark = false
            } else if self.state.bubbleBackdropIsDark == nil {
                self.state.bubbleBackdropIsDark = luminance < 0.46
            }
        }
    }

    // MARK: - 浮遊（アンカー周辺・無限リピートの加算アニメーション）

    /// 周期の異なる正弦波（easeInEaseOutのautoreverse）を加算合成してその場でゆったり漂わせる。
    /// レンダーサーバ側で無限に補間されるため、繋ぎ目もフレーム落ちも存在しない。
    func startFloating() {
        guard state.bubbleActive, !isPopping,
              let assembly = bubbleAssembly, let layer = assembly.layer else { return }
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
        guard let assembly = bubbleAssembly, let layer = assembly.layer else { return }
        if let presentation = layer.presentation() {
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

    // MARK: - バブルの操作（AppKitレベルのマウス処理: クリック=ポヨン / ドラッグ=ウィンドウ移動）

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
        guard state.bubbleActive, let p = bubblePanel, event.window === p else { return false }
        switch event.type {
        case .leftMouseDown:
            guard let frame = bubbleScreenFrame,
                  frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) else { return false }
            dragActive = true
            dragMoved = false
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
            p.setFrameOrigin(origin)
            return true
        case .leftMouseUp:
            guard dragActive else { return false }
            dragActive = false
            dragStartAnchor = nil
            if !dragMoved {
                registerBubbleTap() // クリック = ポヨン、連打で破裂!
            } else if let buttonFrame = statusButtonFrame?(), let onScreen = bubbleScreenFrame {
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
        bounceBubble(intensity: bubbleTapCount == 1 ? 1.0 : 1.6)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        bubbleTapResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            self?.bubbleTapCount = 0
        }
    }

    // MARK: - 割れる（100%）と復活

    func popBubble() {
        guard state.bubbleActive, !isPopping, let assembly = bubbleAssembly else { return }
        isPopping = true
        stopFloating()
        if let onScreen = bubbleScreenFrame {
            lastBubbleCenter = NSPoint(x: onScreen.midX, y: onScreen.midY)
        }

        NSSound(named: "Pop")?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        if let center = lastBubbleCenter {
            showPopBurst(centeredOn: center, scale: Self.bubbleScaleFactor(for: bubbleUsageWindow?.utilization ?? 0))
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            assembly.animator().alphaValue = 0
        }
        bubbleHideGeneration += 1
        let generation = bubbleHideGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.8))
            guard let self else { return }
            self.isPopping = false
            guard self.bubbleHideGeneration == generation else { return }
            self.state.bubbleActive = false
            self.stopMouseTracking()
            self.removeBubbleMouseMonitor()
            self.bubblePanel?.orderOut(nil)
            self.bubbleAssembly?.alphaValue = 1
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
            guard !self.state.bubbleActive else { return }
            await self.usageService.refresh()
            guard (self.bubbleUsageWindow?.utilization ?? 0) < 100 else { return }
            self.showBubble(at: self.lastBubbleCenter ?? self.defaultBubblePoint(), poppingIn: true)
        }
    }

    private func showPopBurst(centeredOn center: NSPoint, scale: CGFloat = 1) {
        let size: CGFloat = 240 * scale
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
        w.contentView = NSHostingView(rootView: PopBurstView(burstScale: scale))
        w.orderFrontRegardless()
        popWindow = w
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.0))
            self?.popWindow?.orderOut(nil)
            self?.popWindow = nil
        }
    }

    /// バブルをメニューバーのステータスアイテム付近へドラッグしたら吸い込まれて消える
    private func snapBackToMenuBar(buttonFrame: NSRect) {
        guard state.bubbleActive, let p = bubblePanel, let assembly = bubbleAssembly else { return }
        state.bubbleActive = false
        revivalTask?.cancel()
        stopFloating()
        stopMouseTracking()
        removeBubbleMouseMonitor()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)

        // ウィンドウは固定のまま、アセンブリをアイコンへ飛ばして縮小フェード
        let targetScreen = NSRect(x: buttonFrame.midX - 6, y: buttonFrame.minY - 10, width: 12, height: 12)
        let target = p.convertFromScreen(targetScreen)
        bubbleHideGeneration += 1
        let generation = bubbleHideGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            assembly.animator().frame = target
            assembly.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.bubbleHideGeneration == generation else { return }
                self.bubblePanel?.orderOut(nil)
                self.bubbleAssembly?.alphaValue = 1
            }
        })
    }
}
