import AppKit
import SwiftUI

/// SwiftUIコンテンツをNSHostingViewで包み、そのレイヤーにCAAnimationを
/// 常駐させるホストの共通基盤（WobbleHostView / DriftHostView が継承）。
///
/// - アニメーションはレンダーサーバで無限補間され、アプリのCPUを使わない
/// - ウィンドウが隠れるとレンダーサーバがアニメーションを破棄するため、
///   オクルージョン変化のたびに張り直す（モデルレイヤーに残る死んだ
///   アニメーションがガードをすり抜けるので、一度removeしてからinstallする）
/// - 「視差効果を減らす」の切替に追従する（この通知はNSWorkspaceの
///   notificationCenterにしか流れない）
/// - クリック/右クリックは外側のSwiftUIとイベントモニタに任せる（hitTest nil）
class CAAnimationHostView: NSView {
    var rootView: AnyView {
        get { hosting.rootView }
        set { hosting.rootView = newValue }
    }

    let hosting: NSHostingView<AnyView>
    private var occlusionObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?

    init(rootView: AnyView) {
        self.hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        // 固定サイズの必須制約を作らせない（ウィンドウ収縮事故の予防・リポジトリ慣例）
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = bounds
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
        if let motionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(motionObserver)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.occlusionState.contains(.visible) == true else { return }
                self.reinstallAnimations()
            }
        }
        if motionObserver == nil {
            motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reinstallAnimations() }
            }
        }
        installAnimationsIfNeeded()
    }

    /// 一度外してから張り直す（死んだアニメーション対策）
    func reinstallAnimations() {
        guard let layer = hosting.layer else { return }
        for key in animationKeys { layer.removeAnimation(forKey: key) }
        installAnimationsIfNeeded()
    }

    /// ガード付きインストール。Reduce Motion時は装飾アニメーションを付けない
    func installAnimationsIfNeeded() {
        guard let layer = hosting.layer else { return }
        guard let first = animationKeys.first, layer.animation(forKey: first) == nil else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        installAnimations(on: layer)
        CATransaction.commit()
    }

    // MARK: - サブクラスが実装する

    /// このホストが管理するアニメーションキー（先頭をインストール済み判定に使う）
    var animationKeys: [String] { [] }

    /// アニメーション本体の構築と layer.add
    func installAnimations(on layer: CALayer) {}
}
