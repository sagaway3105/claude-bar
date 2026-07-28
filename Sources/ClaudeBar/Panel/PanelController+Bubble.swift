import AppKit
import QuartzCore
import SwiftUI

/// バブル（浮遊モード）固有の挙動。
///
/// バブルは専用の透明ウィンドウ（1つ表示=150pt / 3つ表示=300x320pt）で、その中のアセンブリだけを
/// レンダーサーバ側の無限アニメーションで漂わせる（ウィンドウ自体は動かさないので滑らか）。
/// パネルとは独立したウィンドウなので、パネルを開いたままバブルを共存できる。
/// 操作はAppKitのローカルモニタで判定: クリック=ポヨン(連打で破裂) / ドラッグ=ウィンドウ移動 /
/// メニューバー付近で放す=吸着して消える。ホバーで「ポヨン」。
extension PanelController {

    // MARK: - ウィンドウ生成

    func ensureBubblePanel() -> NSPanel {
        if let bubblePanel { return bubblePanel }

        let size = bubbleWindowFrameSize
        // 影なし: アセンブリ移動のたびに影を再計算させない
        let p = makeOverlayPanel(size: size, level: .floating, hasShadow: false)

        let container = PassthroughContainerView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.pinsChildrenToBounds = false // アセンブリは中で自由に漂う

        let assembly = NSView(frame: container.bounds)
        assembly.wantsLayer = true
        assembly.autoresizingMask = []

        let hosting = NSHostingView(
            rootView: BubbleRootView(state: state, settings: settings, cluster: tripleCluster, actions: uiActions)
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
        var launchFrom: NSPoint?
        if let pf = panel, pf.isVisible {
            // フッターの🫧ボタン付近を始点に、なるべく右上へ「ポーン」と飛ばす
            let footerY = pf.frame.maxY - lastPanelSize.height + 34
            launchFrom = NSPoint(x: pf.frame.maxX - 40, y: footerY)
            point = NSPoint(x: pf.frame.maxX + 90, y: footerY + 130)
            if let vf = (pf.screen ?? NSScreen.main)?.visibleFrame {
                point.x = min(max(point.x, vf.minX + 60), vf.maxX - 60)
                point.y = min(max(point.y, vf.minY + 60), vf.maxY - 50)
            }
        }
        showBubble(at: point, poppingIn: true, launchFrom: launchFrom)
    }

    /// バブルを表示（ONにする）。復活・右クリックメニュー・デバッグからも使う。
    /// launchFrom: 指定するとその地点（🫧ボタン付近）からウィンドウごと着地点へ飛ぶ「ポーン」
    func showBubble(at point: NSPoint, poppingIn: Bool = false, launchFrom: NSPoint? = nil) {
        let p = ensureBubblePanel()
        bubbleHideGeneration += 1 // 進行中の遅延orderOutを無効化
        revivalTask?.cancel()
        resetPopRetry?.cancel()
        isPopping = false
        state.bubbleActive = true
        bubbleTrackedResetsAt = bubbleUsageWindow?.resetsAt // リセット境界検知のベースライン
        scheduleResetRefresh()

        let size = bubbleWindowFrameSize
        p.setFrame(
            NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                   width: size.width, height: size.height),
            display: true
        )
        guard let assembly = bubbleAssembly else { return }
        assembly.layer?.removeAllAnimations()
        wasHoveringBubble = false
        if settings.isTripleBubble {
            // 3つ表示: 塊はウィンドウ全体。漂いはSwiftUI側の宣言的アニメーションが担当する
            assembly.frame = NSRect(origin: .zero, size: size)
        } else {
            let diameter = currentBubbleDiameter
            let margin = (size.width - diameter) / 2
            assembly.frame = NSRect(x: margin, y: margin, width: diameter, height: diameter)
        }
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

        if poppingIn {
            // ぽわんっと出現（アセンブリだけ膨らむ）。
            // launchFrom指定時はウィンドウごと始点から着地点へ飛ばして「ポーン」
            let target = assembly.frame
            let finalOrigin = p.frame.origin
            assembly.frame = NSRect(x: target.midX - 4, y: target.midY - 4, width: 8, height: 8)
            if let launchFrom {
                p.setFrameOrigin(NSPoint(x: launchFrom.x - size.width / 2, y: launchFrom.y - size.height / 2))
            }
            assembly.alphaValue = 0
            p.orderFrontRegardless()
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = launchFrom != nil ? 0.6 : 0.34
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.18)
                if launchFrom != nil {
                    // NSWindowのanimatorはsetFrameOriginを無視するためsetFrameで飛ばす
                    p.animator().setFrame(NSRect(origin: finalOrigin, size: p.frame.size), display: true)
                }
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
        resetPopRetry?.cancel()
        resetRefreshTask?.cancel()
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
        let size = bubbleWindowFrameSize
        // 3つ表示では塊がウィンドウをほぼ埋めるのでマージンは取らない
        let margin = settings.isTripleBubble ? 0 : (size.width - currentBubbleDiameter) / 2
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? bubblePanel?.screen ?? NSScreen.main
        guard let vf = screen?.visibleFrame, let sf = screen?.frame else { return }
        floatBounds = NSRect(
            x: sf.minX - margin,
            y: vf.minY - margin,
            width: max(0, sf.width - size.width + margin * 2),
            height: max(0, (sf.maxY - size.height + margin) - (vf.minY - margin))
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
        guard let bubbleOnScreen = bubbleScreenFrame?.insetBy(dx: -6, dy: -6) else { return }
        let inside = bubbleOnScreen.contains(NSEvent.mouseLocation)
        if inside, !wasHoveringBubble, !dragActive,
           Date().timeIntervalSince(lastHoverBounceAt) > 0.6 {
            lastHoverBounceAt = Date()
            bounceBubble() // ポヨン
        }
        // ホバーHUD: 乗ったら遅延表示を予約、離れたら消す
        if inside != wasHoveringBubble {
            if inside, !dragActive {
                scheduleHoverHUD()
            } else {
                hideHoverHUD()
            }
        }
        wasHoveringBubble = inside
    }

    /// 使用量が10%刻みを跨いだらバブルをぷにっと成長させる
    private func growBubbleIfNeeded() {
        guard !settings.isTripleBubble, !dragActive, !isPopping,
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
        hideHoverHUD()
        mouseTrackTimer?.invalidate()
        mouseTrackTimer = nil
        if let activity = napActivity {
            ProcessInfo.processInfo.endActivity(activity)
            napActivity = nil
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

    // MARK: - 3つ表示: 球ごとの破裂と復活

    /// その球だけ割れる（他は残る）。全部割れたらウィンドウを畳む
    func popTripleBall(_ slot: TripleBubbleCluster.Slot) {
        guard !tripleCluster.poppedSlots.contains(slot.index) else { return }
        NSSound(named: "Pop")?.play()
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        if let center = tripleBallScreenCenter(slot) {
            let utilization = state.usage?.window(for: slot.metric)?.utilization ?? 0
            showPopBurst(centeredOn: center, scale: Self.bubbleScaleFactor(for: utilization) * 0.8)
        }
        tripleCluster.pop(slot)
        if tripleCluster.allPopped {
            // 3つとも割れたらバブル自体を畳み、復活を予約する
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.6))
                guard let self, self.tripleCluster.allPopped else { return }
                self.state.bubbleActive = false
                self.stopMouseTracking()
                self.removeBubbleMouseMonitor()
                self.bubblePanel?.orderOut(nil)
            }
        }
    }

    /// 球のスクリーン座標中心（破裂演出の位置決め用）
    private func tripleBallScreenCenter(_ slot: TripleBubbleCluster.Slot) -> NSPoint? {
        guard let p = bubblePanel else { return nil }
        let home = tripleCluster.home(for: slot)
        let drag = tripleCluster.dragOffsets[slot.index]
        // ビュー座標(左上原点) → スクリーン座標(左下原点)
        return NSPoint(
            x: p.frame.origin.x + home.x + drag.width,
            y: p.frame.origin.y + p.frame.height - (home.y + drag.height)
        )
    }

    /// 使用量更新時、3つ表示の各球について100%破裂とリセット復活を判定する
    func updateTripleBallsOnUsage() {
        guard settings.isTripleBubble, state.bubbleActive else { return }
        for slot in TripleBubbleCluster.Slot.allCases {
            let window = state.usage?.window(for: slot.metric)
            let utilization = window?.utilization ?? 0
            if utilization >= 100, !tripleCluster.poppedSlots.contains(slot.index) {
                popTripleBall(slot)
            } else if utilization < 100, tripleCluster.poppedSlots.contains(slot.index),
                      settings.reviveBubble {
                // リセットで使用量が戻った → ぽわんっと生まれ直す
                tripleCluster.revive(slot)
            }
        }
    }

    /// スクリーン座標 → SwiftUIのビュー座標（左上原点）
    private func viewPoint(of screenPoint: NSPoint, in window: NSWindow) -> CGPoint {
        let inWindow = window.convertPoint(fromScreen: screenPoint)
        return CGPoint(x: inWindow.x, y: window.frame.height - inWindow.y)
    }

    private func handleBubbleMouse(_ event: NSEvent) -> Bool {
        guard state.bubbleActive, let p = bubblePanel, event.window === p else { return false }
        switch event.type {
        case .leftMouseDown:
            if settings.isTripleBubble {
                guard p.frame.contains(NSEvent.mouseLocation) else { return false }
                // どの球を掴んだか（塊の余白なら塊ごと動かす）
                tripleCluster.draggingSlot = tripleCluster.slot(
                    at: viewPoint(of: NSEvent.mouseLocation, in: p), state: state
                )
                lastTappedSlot = tripleCluster.draggingSlot
            } else {
                guard let frame = bubbleScreenFrame,
                      frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) else { return false }
            }
            dragActive = true
            dragMoved = false
            dragStartMouse = NSEvent.mouseLocation
            dragStartAnchor = p.frame.origin // バブルではウィンドウ自体を動かす
            hideHoverHUD() // 掴んでいる間はHUDを消す
            return true
        case .leftMouseDragged:
            guard dragActive, let start = dragStartAnchor else { return false }
            let mouse = NSEvent.mouseLocation
            var dx = mouse.x - dragStartMouse.x
            var dy = mouse.y - dragStartMouse.y
            if hypot(dx, dy) > 3 { dragMoved = true }
            if settings.isTripleBubble, let slot = tripleCluster.draggingSlot {
                // 個別ドラッグ: リーシュ内はその球だけ動き、張り詰めた超過分で塊が付いてくる
                // （ビュー座標はy下向きなので符号を反転して渡す）
                let overflow = tripleCluster.dragBall(slot, by: CGSize(width: dx, height: -dy), state: state)
                dx = overflow.width
                dy = -overflow.height
                if abs(dx) < 0.01, abs(dy) < 0.01 { return true }
            }
            var origin = NSPoint(x: start.x + dx, y: start.y + dy)
            origin.x = min(max(origin.x, floatBounds.minX), floatBounds.maxX)
            origin.y = min(max(origin.y, floatBounds.minY), floatBounds.maxY)
            p.setFrameOrigin(origin)
            // 塊が動いた分だけ基準を進め、リーシュの伸びと二重に効かないようにする
            if settings.isTripleBubble, tripleCluster.draggingSlot != nil {
                dragStartMouse = NSPoint(x: dragStartMouse.x + dx, y: dragStartMouse.y + dy)
                dragStartAnchor = origin
            }
            return true
        case .leftMouseUp:
            guard dragActive else { return false }
            dragActive = false
            dragStartAnchor = nil
            if settings.isTripleBubble {
                tripleCluster.releaseBall() // ゆるいばねでホーム配置へ戻る
            }
            if !dragMoved {
                registerBubbleTap() // クリック = ポヨン、連打で破裂!
            } else if let buttonFrame = statusButtonFrame?(), let onScreen = bubbleScreenFrame {
                // メニューバー付近で放したら吸着して戻る
                let zone = buttonFrame.insetBy(dx: -snapMargin, dy: -snapMargin)
                if zone.contains(NSPoint(x: onScreen.midX, y: onScreen.midY)) {
                    snapBackToMenuBar(buttonFrame: buttonFrame)
                }
            }
            scheduleHoverHUD() // まだバブル上にいれば少し後にHUDを出し直す
            return true
        default:
            return false
        }
    }

    /// バブルのクリック遊び: 1回目ポヨン、2回目強めのポヨン、3連打で破裂💥
    private func registerBubbleTap() {
        bubbleTapCount += 1
        bubbleTapResetTask?.cancel()

        // 3つ表示では掴んでいた球だけが反応する（他の球は残る）
        if settings.isTripleBubble {
            guard let slot = lastTappedSlot else { bubbleTapCount = 0; return }
            if bubbleTapCount >= 3 {
                bubbleTapCount = 0
                popTripleBall(slot)
                return
            }
            tripleCluster.bounce(slot, intensity: bubbleTapCount == 1 ? 1.0 : 1.6)
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            bubbleTapResetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.1))
                guard !Task.isCancelled else { return }
                self?.bubbleTapCount = 0
            }
            return
        }

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
        startPop { [weak self] in
            guard let self else { return }
            self.state.bubbleActive = false
            self.stopMouseTracking()
            self.removeBubbleMouseMonitor()
            self.bubblePanel?.orderOut(nil)
            self.bubbleAssembly?.alphaValue = 1
            self.scheduleRevivalIfNeeded()
        }
    }

    /// 破裂の共通演出（音・触覚・バースト・フェードアウト）。0.8秒後に completion を呼ぶ。
    /// completion は「消して復活予約」（手動破裂）か「同じ場所に生まれ直す」（リセット破裂）で分岐する。
    private func startPop(then completion: @escaping () -> Void) {
        guard state.bubbleActive, !isPopping, let assembly = bubbleAssembly else { return }
        isPopping = true
        stopFloating()
        hideHoverHUD()
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
            completion()
        }
    }

    /// 表示中メトリクスの制限がリセットされた時: 弾けてから同じ場所に新しいバブルが生まれる。
    /// 手動破裂と違い「割れた後リセット時に復活」設定に依存しない（生きているバブルの生まれ変わり）。
    func popForReset() {
        guard state.bubbleActive, !isPopping else { return }
        // 掴んでいる最中は消さず、放してから演出する
        if dragActive {
            resetPopRetry?.cancel()
            resetPopRetry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                self.popForReset()
            }
            return
        }
        let center = bubbleScreenFrame.map { NSPoint(x: $0.midX, y: $0.midY) }
            ?? lastBubbleCenter ?? defaultBubblePoint()
        bubbleTapCount = 0
        startPop { [weak self] in
            // 破裂しきってから、更新後の数字（0%付近）で同じ場所にポップイン
            self?.showBubble(at: center, poppingIn: true)
        }
    }

    /// 使用量更新のたびに呼ばれる。表示中メトリクスがリセット境界を越えていたら破裂演出を起こす。
    /// （検知はデータ駆動で確実に、発火の即時性は scheduleResetRefresh のタイマーで担保する）
    func onUsageUpdated() {
        updateTripleBallsOnUsage()
        guard state.bubbleActive, !isPopping else {
            bubbleTrackedResetsAt = bubbleUsageWindow?.resetsAt
            return
        }
        let newResets = bubbleUsageWindow?.resetsAt
        defer {
            bubbleTrackedResetsAt = newResets
            scheduleResetRefresh()
        }
        guard let prev = bubbleTrackedResetsAt, let newResets else { return }
        // 追跡中だったリセット時刻を過ぎ、ウィンドウが新しい期間へ進んだ = リセット発生
        if newResets > prev.addingTimeInterval(60), prev.timeIntervalSinceNow < 60 {
            popForReset()
        }
    }

    /// 表示中メトリクスのリセット時刻+90秒に使用量の再取得を予約する。
    /// 取得結果で onUsageUpdated が境界越えを検知し、ポーリングを待たず数分以内に破裂→再生成が始まる
    private func scheduleResetRefresh() {
        resetRefreshTask?.cancel()
        guard state.bubbleActive,
              let resets = bubbleUsageWindow?.resetsAt,
              resets.timeIntervalSinceNow > 0 else { return }
        let delay = resets.timeIntervalSinceNow + 90
        resetRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await self.usageService.refresh()
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

    func showPopBurst(centeredOn center: NSPoint, scale: CGFloat = 1) {
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
        resetPopRetry?.cancel()
        resetRefreshTask?.cancel()
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
