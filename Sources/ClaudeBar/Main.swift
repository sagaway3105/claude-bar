import AppKit

@main
enum ClaudeBarMain {
    static func main() {
        // 多重起動ガード（.app起動時のみ）
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty { exit(0) }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var settings: SettingsStore!
    private var notifier: NotificationService!
    private var usageService: UsageService!
    private var activityMonitor: ActivityMonitor!
    private var panelController: PanelController!
    private var statusController: StatusItemController!
    private var settingsController: SettingsWindowController!
    private var debugBridge: DebugBridge?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let state = AppState()
        self.state = state
        settings = SettingsStore()
        notifier = NotificationService()
        usageService = UsageService(state: state, settings: settings, notifier: notifier)
        settingsController = SettingsWindowController(settings: settings)
        panelController = PanelController(state: state, usageService: usageService, settings: settings)
        statusController = StatusItemController(state: state, panelController: panelController)

        panelController.statusButtonFrame = { [weak self] in
            self?.statusController.buttonScreenFrame
        }
        panelController.onOpenSettings = { [weak self] in
            self?.settingsController.show()
        }
        panelController.setStatusHighlighted = { [weak self] highlighted in
            self?.statusController.setHighlighted(highlighted)
        }

        activityMonitor = ActivityMonitor { [weak self] in
            DispatchQueue.main.async {
                self?.state.registerActivity()
                self?.usageService.refreshIfStale(olderThan: 60)
            }
        }
        activityMonitor.start()
        usageService.startPolling()

        debugBridge = DebugBridge(
            state: state,
            usageService: usageService,
            panelController: panelController,
            statusController: statusController,
            settingsController: settingsController
        )
    }
}
