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

        // ウィンドウリサイズの犯人特定用: 全リサイズをスタック付きでstderrへ
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow, window is NSPanel else { return }
            let stack = Thread.callStackSymbols.prefix(10).joined(separator: "\n")
            let line = "RESIZE -> \(window.frame)\n\(stack)\n\n"
            FileHandle.standardError.write(line.data(using: .utf8)!)
        }
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
        case "overlay":
            panelController.uiActions.toOverlay()
        case "checkupdate":
            panelController.updater?.checkForUpdates()
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
            } else if command.hasPrefix("needslogin:") {
                state.needsLogin = command.hasSuffix("1")
            }
        }
    }

    private func writeState() {
        var info: [String: Any] = [:]
        switch state.mode {
        case .attached: info["mode"] = "attached"
        case .floating: info["mode"] = "floating"
        }
        info["bubbleActive"] = state.bubbleActive
        info["highlighted"] = state.menuHighlighted
        if let frame = panelController.debugPanelFrame {
            info["panel"] = [frame.origin.x, frame.origin.y, frame.width, frame.height]
            info["visible"] = panelController.debugPanelVisible
        }
        if let w = panelController.panel {
            info["window"] = [w.frame.origin.x, w.frame.origin.y, w.frame.width, w.frame.height]
            let content = w.contentRect(forFrameRect: w.frame)
            info["contentRect"] = [content.width, content.height]
            info["contentViewIsContainer"] = (w.contentView === panelController.containerView)
        }
        if let c = panelController.containerView {
            info["container"] = [c.frame.origin.x, c.frame.origin.y, c.frame.width, c.frame.height]
        }
        if let a = panelController.assemblyView {
            info["assemblyModel"] = [a.frame.origin.x, a.frame.origin.y, a.frame.width, a.frame.height]
            if let pres = a.layer?.presentation() {
                info["assemblyPresentation"] = [pres.position.x, pres.position.y]
            }
        }
        if let h = panelController.contentHosting {
            info["hosting"] = [h.frame.origin.x, h.frame.origin.y, h.frame.width, h.frame.height]
        }
        if let screen = NSScreen.main {
            info["screen"] = [screen.frame.width, screen.frame.height]
        }
        info["statusBarThickness"] = NSStatusBar.system.thickness
        if statusController.buttonScreenFrame != nil, let bw = NSApp.windows.first(where: { $0.className.contains("StatusBar") }) {
            info["statusWindow"] = [bw.frame.origin.x, bw.frame.origin.y, bw.frame.width, bw.frame.height]
        }
        if let buttonFrame = statusController.buttonScreenFrame {
            info["statusItem"] = [buttonFrame.origin.x, buttonFrame.origin.y, buttonFrame.width, buttonFrame.height]
        }
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            try? data.write(to: cmdURL.appendingPathExtension("state"))
        }
    }
}
