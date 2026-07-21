import AppKit
import Foundation

/// UI検証用のコマンドブリッジ。
/// CLAUDEBAR_DEBUG=1 かつ CLAUDEBAR_CMDFILE=<path> で起動した時のみ有効。
/// コマンドファイルに1行ずつ書き込むと実行される:
///   click / bubble / expand / pop / hide / settings / quit
///   usage:<session>,<weekly>,<fable>   例: usage:83,41,12
///   active:1 / active:0                （ロゴアニメのon/off）
///   err:<メッセージ> / err:
///   state                              （<cmdfile>.state にJSONを書き出す）
@MainActor
final class DebugBridge {
    private var timer: Timer?
    private let cmdURL: URL
    private let state: AppState
    private let usageService: UsageService
    private let panelController: PanelController
    private let statusController: StatusItemController
    private let settingsController: SettingsWindowController

    init?(
        state: AppState,
        usageService: UsageService,
        panelController: PanelController,
        statusController: StatusItemController,
        settingsController: SettingsWindowController
    ) {
        let env = ProcessInfo.processInfo.environment
        guard env["CLAUDEBAR_DEBUG"] == "1", let path = env["CLAUDEBAR_CMDFILE"] else { return nil }
        cmdURL = URL(fileURLWithPath: path)
        self.state = state
        self.usageService = usageService
        self.panelController = panelController
        self.statusController = statusController
        self.settingsController = settingsController

        FileManager.default.createFile(atPath: path, contents: Data())
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard let text = try? String(contentsOf: cmdURL, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try? Data().write(to: cmdURL)
        for line in text.split(separator: "\n") {
            handle(String(line).trimmingCharacters(in: .whitespaces))
        }
    }

    private func handle(_ command: String) {
        switch command {
        case "click":
            statusController.performClick()
        case "bubble":
            panelController.showBubbleNearStatusItem()
        case "tobubble":
            panelController.uiActions.toBubble()
        case "expand":
            panelController.expandFromBubble()
        case "pop":
            panelController.popBubble()
        case "hide":
            panelController.hide()
        case "settings":
            settingsController.show()
        case "quit":
            NSApp.terminate(nil)
        case "state":
            writeState()
        default:
            if command.hasPrefix("usage:") {
                let parts = command.dropFirst(6).split(separator: ",").map { Double($0) }
                usageService.applyFake(
                    session: parts.count > 0 ? parts[0] : nil,
                    weekly: parts.count > 1 ? parts[1] : nil,
                    fable: parts.count > 2 ? parts[2] : nil
                )
            } else if command.hasPrefix("active:") {
                if command.hasSuffix("1") {
                    state.registerActivity()
                } else {
                    state.isActive = false
                }
            } else if command.hasPrefix("err:") {
                let message = String(command.dropFirst(4))
                state.errorMessage = message.isEmpty ? nil : message
            }
        }
    }

    private func writeState() {
        var info: [String: Any] = [:]
        switch state.mode {
        case .attached: info["mode"] = "attached"
        case .bubble: info["mode"] = "bubble"
        case .floating: info["mode"] = "floating"
        }
        if let frame = panelController.debugPanelFrame {
            info["panel"] = [frame.origin.x, frame.origin.y, frame.width, frame.height]
            info["visible"] = panelController.debugPanelVisible
        }
        if let screen = NSScreen.main {
            info["screen"] = [screen.frame.width, screen.frame.height]
        }
        if let buttonFrame = statusController.buttonScreenFrame {
            info["statusItem"] = [buttonFrame.origin.x, buttonFrame.origin.y, buttonFrame.width, buttonFrame.height]
        }
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            try? data.write(to: cmdURL.appendingPathExtension("state"))
        }
    }
}
