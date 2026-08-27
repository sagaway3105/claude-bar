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
    private var updater: UpdaterService!
    #if DEBUG
    private var debugBridge: DebugBridge?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        // 検証用: CLAUDEBAR_APPEARANCE=dark|light でアプリ外観を固定する
        // （システム設定を切り替えずにライト/ダーク両方のスタイルを確認するため）
        switch ProcessInfo.processInfo.environment["CLAUDEBAR_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        #endif

        let state = AppState()
        self.state = state
        settings = SettingsStore()
        notifier = NotificationService()
        usageService = UsageService(state: state, settings: settings, notifier: notifier)
        updater = UpdaterService()
        settingsController = SettingsWindowController(settings: settings, updater: updater)
        settingsController.state = state
        panelController = PanelController(state: state, usageService: usageService, settings: settings)
        statusController = StatusItemController(state: state, panelController: panelController)
        panelController.updater = updater

        panelController.statusButtonFrame = { [weak self] in
            self?.statusController.buttonScreenFrame
        }
        panelController.onOpenSettings = { [weak self] in
            self?.settingsController.show()
        }
        // 使用量更新のたびにバブルへ通知（表示中メトリクスのリセットで破裂→再生成させる）
        usageService.onUsageApplied = { [weak self] in
            self?.panelController.onUsageUpdated()
        }
        // 表示個数（1つ⇔3つ）の切替時、表示中のバブルを新モードで組み直す
        settings.onBubbleCountChanged = { [weak self] in
            self?.panelController.relayoutBubbleForCountChange()
        }

        activityMonitor = ActivityMonitor { [weak self] in
            DispatchQueue.main.async {
                self?.state.registerActivity()
                self?.usageService.refreshIfStale(olderThan: 60)
            }
        }
        activityMonitor.start()
        usageService.startPolling()
        // 自動アップデート（.app起動時のみ有効）。設定の初期値を反映
        updater.start()
        if updater.isAvailable {
            updater.automaticallyChecksForUpdates = settings.autoUpdate
            updater.automaticallyDownloadsUpdates = settings.autoUpdate
        }

        #if DEBUG
        debugBridge = DebugBridge(
            state: state,
            usageService: usageService,
            panelController: panelController,
            statusController: statusController,
            settingsController: settingsController
        )
        #endif

        // 初回起動: 機能説明 → パネルを一度だけ自動展開
        OnboardingDialog.showIfNeeded { [weak self] in
            self?.statusController.performClick()
        }
    }
}
