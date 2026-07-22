import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let panelController: PanelController
    private let state: AppState

    init(state: AppState, panelController: PanelController) {
        self.panelController = panelController
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        guard let button = statusItem.button else { return }
        // 空のNSButtonの固有幅(~27pt)に潰されないよう、SwiftUI側の実測幅をlengthへ反映する
        let hosting = PassthroughHostingView(rootView: StatusLabelView(state: state) { [weak statusItem] width in
            statusItem?.length = width
        })
        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: button.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        button.target = self
        button.action = #selector(didClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // レガシーな黒い押下ハイライトを抑止（ハイライトはSwiftUI側でApple純正風に描く）
        (button.cell as? NSButtonCell)?.highlightsBy = []
    }

    /// ステータスアイテムのスクリーン座標（バブルの吸着判定などに使う）
    var buttonScreenFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// デバッグ用: クリックをシミュレート
    func performClick() {
        guard let button = statusItem.button else { return }
        panelController.toggle(relativeTo: button)
    }

    /// パネルが開いている間、Apple純正メニュー風の薄いカプセルハイライトを表示
    func setHighlighted(_ highlighted: Bool) {
        state.menuHighlighted = highlighted
    }

    @objc private func didClick() {
        guard let button = statusItem.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(on: button)
        } else {
            panelController.toggle(relativeTo: button)
        }
    }

    private func showContextMenu(on button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(makeItem("今すぐ更新", #selector(refreshNow)))
        menu.addItem(makeItem("バブルで表示", #selector(showBubble)))
        menu.addItem(.separator())
        menu.addItem(makeItem("設定…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(makeItem("ClaudeBarを終了", #selector(quit)))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 6), in: button)
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func refreshNow() { panelController.uiActions.refresh() }
    @objc private func showBubble() { panelController.showBubbleNearStatusItem() }
    @objc private func openSettings() { panelController.uiActions.settings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
