import AppKit
import QuartzCore
import SwiftUI

/// バブル（浮遊モード）固有の挙動。
///
/// バブルは専用の透明ウィンドウ（1つ表示=150pt角 / 3つ表示=220x210pt）で、その中のアセンブリだけを
/// レンダーサーバ側の無限アニメーションで漂わせる（ウィンドウ自体は動かさないので滑らか）。
/// パネルとは独立したウィンドウなので、パネルを開いたままバブルを共存できる。
/// 操作はAppKitのローカルモニタで判定: クリック=ポヨン(連打で破裂) / ドラッグ=ウィンドウ移動 /
/// メニューバー付近で放す=吸着して消える。ホバーで「ポヨン」。
///
/// ここは1つ表示・3つ表示に共通の仕組み。球ごとに分かれる処理は
/// PanelController+TripleBubble.swift にある。
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
        #if DEBUG
        // 透明ウィンドウの実際の範囲を可視化する（レイアウト検証用）
        if ProcessInfo.processInfo.environment["CLAUDEBAR_TINT_WINDOW"] == "1" {
            container.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.18).cgColor
        }
        #endif

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
        bubbleAssembly = assembly
        bubbleHosting = hosting
        // 画面ロック・ディスプレイスリープ等（orderOutを経ない非表示）でも
        // 宣言的アニメーションは破棄されるため、可視化のたびに漂いを始め直す
        bubbleOcclusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state.bubbleActive,
                      self.bubblePanel?.occlusionState.contains(.visible) == true else { return }
                if self.settings.isTripleBubble {
                    self.tripleCluster.showGeneration += 1
                }
                // 塊の浮遊も同条件で破棄される。モデル側に残る死んだアニメーションが
                // startFloating の in-needed ガードを塞ぐため、外してから張り直す
                if let layer = self.bubbleAssembly?.layer {
                    for key in ["float-x1", "float-x2", "float-y1", "float-y2"] {
                        layer.removeAnimation(forKey: key)
                    }
                }
                self.startFloating()
            }
        }
        return p
    }

    /// アセンブリの中身を現在の表示個数に合わせて組み直す。
    ///
    /// **3つ表示は球ごとに独立したホスティングビューを兄弟として並べる。**
    /// `glassEffect` の描画は最も外側のNSHostingViewを基準にウィンドウ単位のガラス群へ
    /// 持ち上げられ、その内側のレイヤーアニメーションを無視するため、1枚のホスティング
    /// ビューに3球を入れると球ごとの漂い（DriftHost）が画面に出ない（2026-08-27実測）。
    /// ホストを分ければ持ち上げ先も分かれ、3球とも背後を採取しつつ独立に漂う。
    /// 重なり順はサブビューの追加順（最後＝最前面）で作る
    func configureBubbleContent(in assembly: NSView) {
        if settings.isTripleBubble {
            bubbleHosting?.removeFromSuperview()
            if tripleHosts.isEmpty {
                // 配列は**スロット順**（セッション/Fable/週間）で持つ。
                // 幾何の計算で `tripleHosts[slot.index]` を引けるようにするため。
                // 重なり順は addSubview の順（背面＝週間から）で作る
                tripleHosts = TripleBubbleCluster.Slot.allCases.map { slot in
                    let p = tripleCluster.driftParams(for: slot)
                    let host = DriftHostView(
                        rootView: AnyView(TripleBallCanvas(
                            slot: slot, state: state, settings: settings,
                            cluster: tripleCluster, actions: uiActions
                        )),
                        amplitudeX: p.ax, durationX: p.dx,
                        amplitudeY: p.ay, durationY: p.dy,
                        phase: p.phase
                    )
                    // 球の上のクリック/右クリックは中のSwiftUIへ届かせる
                    host.passesMouseThrough = false
                    return host
                }
            }
            for host in tripleHosts.reversed() {   // 週間 → Fable → セッションの順に積む
                host.frame = assembly.bounds
                host.hosting.frame = host.bounds
                if host.superview !== assembly { assembly.addSubview(host) }
            }
        } else {
            for host in tripleHosts { host.removeFromSuperview() }
            tripleHosts = []
            guard let hosting = bubbleHosting else { return }
            hosting.frame = assembly.bounds
            if hosting.superview !== assembly { assembly.addSubview(hosting) }
        }
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
        tripleCluster.contentParked = false // 畳んでいた中身を戻す
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
            // 3つ表示: 塊はウィンドウ全体（アセンブリの漂いが塊ごとの揺れ、
            // 球ごとの揺れはSwiftUI側の宣言的アニメーションが担当する）
            reviveTripleBallsBelowLimit()
            tripleCluster.showGeneration += 1 // 球ごとの漂いを確実に始め直す
            assembly.frame = NSRect(origin: .zero, size: size)
        } else {
            let diameter = currentBubbleDiameter
            let margin = (size.width - diameter) / 2
            assembly.frame = NSRect(x: margin, y: margin, width: diameter, height: diameter)
        }
        assembly.alphaValue = 1
        configureBubbleContent(in: assembly)

        updateFloatBounds(around: point)
        // 新しいモードのサイズで画面からはみ出す位置なら押し込む
        // （1⇔3切替・復活の再表示は元の中心を引き継ぐため、端では欠けることがある）
        var clamped = p.frame.origin
        clamped.x = min(max(clamped.x, floatBounds.minX), floatBounds.maxX)
        clamped.y = min(max(clamped.y, floatBounds.minY), floatBounds.maxY)
        if clamped != p.frame.origin { p.setFrameOrigin(clamped) }
        p.ignoresMouseEvents = false // 初期状態は受ける（以後はカーソル位置で自動切替）
        startMouseTracking()
        installBubbleMouseMonitor()
        // アクセサリアプリはApp Napでタイマーが間引かれるため、バブル表示中は抑止する。
        // ※ .userInitiated は idleSystemSleepDisabled を含み、バブル表示中は
        //   Macがアイドルスリープできなくなるため、スリープを許す方を使う
        if napActivity == nil {
            napActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep], reason: "Bubble float animation"
            )
        }

        // 100%のまま再表示された場合は破裂させる。ビューは再生成されないため
        // BubbleView側のonChange（100到達検知）や初回チェックは発火しない
        if !settings.isTripleBubble, (bubbleUsageWindow?.utilization ?? 0) >= 100 {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard let self, self.state.bubbleActive, !self.isPopping else { return }
                guard (self.bubbleUsageWindow?.utilization ?? 0) >= 100 else { return }
                self.popBubble()
            }
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
                self.tripleCluster.contentParked = true
            }
        })
    }

    func showBubbleNearStatusItem() {
        showBubble(at: defaultBubblePoint(), poppingIn: true)
    }

    /// 設定で表示個数（1つ⇔3つ）が変わった時: 表示中ならその場で組み直す。
    /// SwiftUI側は設定を監視して即切り替わるため、放置するとウィンドウサイズ・
    /// アセンブリ・当たり判定だけが旧モードのまま残って表示が壊れる
    func relayoutBubbleForCountChange() {
        guard state.bubbleActive, let p = bubblePanel else { return }
        let center = NSPoint(x: p.frame.midX, y: p.frame.midY)
        tripleCluster.releaseBall()
        showBubble(at: center)
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
    /// ウィンドウの外形ではなく「見えているバブルの縁」が画面の縁に届く基準:
    /// 左右・下は画面端（下はDockの上端）に接するまで、上はメニューバーを覆えるまで。
    /// 3つ表示も同じ基準（見えている塊の外接とウィンドウ縁の距離を辺ごとに余裕にする）
    func updateFloatBounds(around point: NSPoint) {
        let size = bubbleWindowFrameSize
        let left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat
        if settings.isTripleBubble, let bounds = tripleClusterBounds() {
            // ビュー座標は左上原点: bounds.minY はウィンドウ上端から塊上端までの距離
            left = bounds.minX
            right = size.width - bounds.maxX
            top = bounds.minY
            bottom = size.height - bounds.maxY
        } else {
            let margin = (size.width - currentBubbleDiameter) / 2
            left = margin; right = margin; top = margin; bottom = margin
        }
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? bubblePanel?.screen ?? NSScreen.main
        guard let vf = screen?.visibleFrame, let sf = screen?.frame else { return }
        floatBounds = NSRect(
            x: sf.minX - left,
            y: vf.minY - bottom,
            width: max(0, sf.width - size.width + left + right),
            height: max(0, (sf.maxY - size.height + top) - (vf.minY - bottom))
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

    /// ホバー（ポヨン・HUD）の発火領域。3つ表示はウィンドウ全体ではなく
    /// 見えている塊の外接基準にする（クリックは抜けるのにホバーだけ反応する不整合を防ぐ。
    /// -12ptの余裕は塊全体の浮遊±8.5〜9.5ptぶん）
    var bubbleHoverZone: NSRect? {
        if settings.isTripleBubble, let p = bubblePanel {
            return tripleClusterScreenBounds(in: p)?.insetBy(dx: -12, dy: -12)
        }
        return bubbleScreenFrame?.insetBy(dx: -6, dy: -6)
    }

    private func trackMouse() {
        guard state.bubbleActive else { return }
        growBubbleIfNeeded()
        updateBubbleClickability()
        guard let bubbleOnScreen = bubbleHoverZone else { return }
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

    /// カーソルが球の上にある時だけクリックを受け、それ以外（ウィンドウの透明な余白）は
    /// クリックを下のウィンドウへ確実に通す。アルファ値の自動ヒット判定に任せると
    /// グローの薄い被膜まで奪って境界が曖昧になるため、明示的に切り替える
    private func updateBubbleClickability() {
        guard let p = bubblePanel else { return }
        if dragActive {
            p.ignoresMouseEvents = false // 掴んでいる間は受けたまま
            return
        }
        let overBall: Bool
        if settings.isTripleBubble {
            overBall = p.frame.contains(NSEvent.mouseLocation)
                && tripleSlot(at: NSEvent.mouseLocation, in: p) != nil
        } else {
            overBall = bubbleScreenFrame?.insetBy(dx: -6, dy: -6).contains(NSEvent.mouseLocation) ?? false
        }
        p.ignoresMouseEvents = !overBall
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
        // 3つ表示は球ごとの漂い（DriftHost）が上に乗るので、塊側を下げて
        // 見た目の総移動量を1つ表示（＝v1.5.3の体感）と同じくらいに保つ
        let g: CGFloat = settings.isTripleBubble ? 0.55 : 1
        layer.add(floatAnimation("position.x", amplitude: 6 * g, duration: 3.7, phase: 0), forKey: "float-x1")
        layer.add(floatAnimation("position.x", amplitude: 2.5 * g, duration: 6.1, phase: 1.7), forKey: "float-x2")
        layer.add(floatAnimation("position.y", amplitude: 7 * g, duration: 4.4, phase: 1.1), forKey: "float-y1")
        layer.add(floatAnimation("position.y", amplitude: 2.5 * g, duration: 7.9, phase: 3.0), forKey: "float-y2")
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
            if settings.isTripleBubble {
                guard p.frame.contains(NSEvent.mouseLocation) else { return false }
                // どの球を掴んだか（浮遊ぶんを補正して見た目どおりに判定）。
                // 球の外の余白は通常 ignoresMouseEvents で下へ抜けるため
                // ここへ来るのは球の上がほぼ全て（nilは切替タイミングの隙間のフォールバック）
                tripleCluster.draggingSlot = tripleSlot(at: NSEvent.mouseLocation, in: p)
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
            registerTripleBubbleTap()
            return
        }

        if bubbleTapCount >= 3 {
            bubbleTapCount = 0
            popBubble()
            return
        }
        bounceBubble(intensity: bubbleTapCount == 1 ? 1.0 : 1.6)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        scheduleBubbleTapReset()
    }

    /// 連打の間隔が空いたら回数をリセットする（1.1秒）
    func scheduleBubbleTapReset() {
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
            self.tripleCluster.contentParked = true
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

        // 「ぐぐ...パチン」。音の前半（軋み）に合わせて球を膨らませ、パチンで割る。
        // 音を切っていても**溜めと破裂の見た目はそのまま**（演出まで消すと手応えが無くなる）
        playPopSound()
        strainBubble(assembly)

        bubbleHideGeneration += 1
        let generation = bubbleHideGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(PanelController.popStrainDuration))
            guard let self, self.bubbleHideGeneration == generation else { return }
            // ここが「パチン」の瞬間。中心は**この時点で**取り直す
            // （溜めの前に取った位置を使うと、破裂が球からずれて出る）
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            if let onScreen = self.bubbleScreenFrame {
                self.lastBubbleCenter = NSPoint(x: onScreen.midX, y: onScreen.midY)
            }
            if let center = self.lastBubbleCenter {
                self.showPopBurst(
                    centeredOn: center,
                    // 溜めで膨らんだぶん、破裂も一回り大きく出す
                    scale: Self.bubbleScaleFactor(for: self.bubbleUsageWindow?.utilization ?? 0) * 1.16
                )
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                assembly.animator().alphaValue = 0
            }, completionHandler: nil)
            try? await Task.sleep(for: .seconds(0.6))
            guard self.bubbleHideGeneration == generation else { return }
            self.isPopping = false
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
        refitHoverHUD() // 表示中HUDの幅を新しい内容に合わせる
        guard state.bubbleActive, !isPopping else {
            bubbleTrackedResetsAt = bubbleUsageWindow?.resetsAt
            return
        }
        if settings.isTripleBubble {
            // 3つ表示のリセット破裂・復活は球ごと（updateTripleBallsOnUsage）。
            // 単発用メトリクスの境界検知で塊全体を破裂させない
            scheduleResetRefresh()
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

    /// リセット時刻+90秒に使用量の再取得を予約する（1つ表示は表示中メトリクス、
    /// 3つ表示は最初に来るリセット）。取得結果で onUsageUpdated が境界越えや球の復活を
    /// 検知し、ポーリングを待たず数分以内に破裂→再生成が始まる
    private func scheduleResetRefresh() {
        resetRefreshTask?.cancel()
        let next = settings.isTripleBubble ? tripleNextResetsAt : bubbleUsageWindow?.resetsAt
        guard state.bubbleActive,
              let resets = next,
              resets.timeIntervalSinceNow > 0 else { return }
        let delay = resets.timeIntervalSinceNow + 90
        resetRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await self.usageService.refresh()
        }
    }

    /// 設定が有効なら、リセット後にバブルを復活させる。
    /// 1つ表示は表示中メトリクス、3つ表示（全滅時）は3メトリクスのうち最初に来るリセットが基準
    func scheduleRevivalIfNeeded() {
        revivalTask?.cancel()
        let nextResets = settings.isTripleBubble ? tripleNextResetsAt : bubbleUsageWindow?.resetsAt
        guard settings.reviveBubble,
              let resets = nextResets,
              resets.timeIntervalSinceNow > 0 else { return }
        let delay = resets.timeIntervalSinceNow + 90
        revivalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            // リセット直後の取得は空振りし得る（進行中のポーリングと重なって捨てられる・
            // フォールバックが前期間のキャッシュを返す等）ため、少し置いて数回試す
            for attempt in 0..<3 {
                guard let self, !Task.isCancelled else { return }
                guard !self.state.bubbleActive else { return }
                await self.usageService.refresh()
                let canRevive = self.settings.isTripleBubble
                    ? self.tripleCanRevive
                    : (self.bubbleUsageWindow?.utilization ?? 0) < 100
                if canRevive {
                    self.showBubble(at: self.lastBubbleCenter ?? self.defaultBubblePoint(), poppingIn: true)
                    return
                }
                if attempt < 2 { try? await Task.sleep(for: .seconds(60)) }
            }
            // それでも100%のまま → 次のリセット時刻が取れていれば予約し直す
            self?.scheduleRevivalIfNeeded()
        }
    }

    /// 破裂音を鳴らす（設定でオフにできる）。連続破裂では鳴らし直す
    func playPopSound() {
        guard settings.popSound else { return }
        PanelController.popSound?.stop()
        PanelController.popSound?.play()
    }

    /// 破裂前の「ぐぐぐ」: 球がじわっと膨らみ、最後に一段強く張る。
    /// SwiftUIのscaleEffectはガラスの円形マスクで切れるため、レイヤー変形で行う
    /// （`bounceBubble` と同じ流儀）
    func strainBubble(_ assembly: NSView) {
        guard let layer = assembly.layer else { return }
        let cx = assembly.bounds.width / 2
        let cy = assembly.bounds.height / 2
        func scaled(_ s: CGFloat) -> CATransform3D {
            var m = CATransform3DMakeTranslation(cx * (1 - s), cy * (1 - s), 0)
            m = CATransform3DScale(m, s, s, 1)
            return m
        }
        let strain = CAKeyframeAnimation(keyPath: "transform")
        // ゆっくり張る → 最後に一段ふくらむ（音の軋みが速くなるところに合わせる）
        strain.values = [scaled(1.0), scaled(1.035), scaled(1.06), scaled(1.10), scaled(1.16)]
        strain.keyTimes = [0, 0.35, 0.6, 0.85, 1]
        strain.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4
        )
        strain.duration = PanelController.popStrainDuration
        strain.fillMode = .forwards
        strain.isRemovedOnCompletion = false
        layer.add(strain, forKey: "pop-strain")
    }

    func showPopBurst(centeredOn center: NSPoint, scale: CGFloat = 1) {
        let size: CGFloat = 240 * scale
        // **UnconstrainedPanel を使うこと**。素の NSWindow だと AppKit の
        // `constrainFrameRect` が「上端はメニューバーの下」へ黙ってクランプし、
        // メニューバー付近のバブルを割ったときに破裂だけ下へずれて出る（実測で最大65pt）
        let w = makeOverlayPanel(size: NSSize(width: size, height: size), level: .floating, hasShadow: false)
        w.setFrameOrigin(NSPoint(x: center.x - size / 2, y: center.y - size / 2))
        w.ignoresMouseEvents = true
        w.contentView = NSHostingView(rootView: PopBurstView(burstScale: scale))
        w.orderFrontRegardless()
        #if DEBUG
        if ProcessInfo.processInfo.environment["CLAUDEBAR_TRACE_POP"] == "1" {
            FileHandle.standardError.write(
                "POP center=\(center) size=\(size) windowFrame=\(w.frame)\n".data(using: .utf8)!)
        }
        #endif
        // 連続破裂（2球がほぼ同時に100%到達など）: 前のバーストを参照ごと潰さず、
        // それぞれのウィンドウが自分の演出を全うしてから片付ける
        popWindow = w
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.0))
            w.orderOut(nil)
            if let self, self.popWindow === w { self.popWindow = nil }
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
                self.tripleCluster.contentParked = true
            }
        })
    }
}
