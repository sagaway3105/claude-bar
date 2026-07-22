import Foundation
import Observation
import ServiceManagement

/// バブルに表示する使用量の種類
enum BubbleMetric: String, CaseIterable {
    case session // 現在のセッション
    case weekly  // 週間（すべてのモデル）
    case fable   // Fable（週間）
}

@MainActor
@Observable
final class SettingsStore {
    private static let defaults = UserDefaults.standard
    private var isLoaded = false

    /// ログイン時起動はSMAppService（.appバンドルからの起動でのみ変更可能）
    let canManageLoginItem = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"

    var notifyThresholds: Bool {
        didSet { persist(notifyThresholds, "notifyThresholds") }
    }

    var pollIntervalMinutes: Int {
        didSet { persist(pollIntervalMinutes, "pollIntervalMinutes") }
    }

    var reviveBubble: Bool {
        didSet { persist(reviveBubble, "reviveBubble") }
    }

    var bubbleMetric: BubbleMetric {
        didSet { persist(bubbleMetric.rawValue, "bubbleMetric") }
    }

    /// バーの色をmacOSのアクセントカラーに合わせる（falseならClaudeオレンジ）
    var useSystemAccent: Bool {
        didSet { persist(useSystemAccent, "useSystemAccent") }
    }

    var launchAtLogin: Bool {
        didSet { updateLoginItem() }
    }

    init() {
        Self.defaults.register(defaults: [
            "notifyThresholds": true,
            "pollIntervalMinutes": 2,
            "reviveBubble": true,
            "bubbleMetric": BubbleMetric.session.rawValue,
            "useSystemAccent": true,
        ])
        notifyThresholds = Self.defaults.bool(forKey: "notifyThresholds")
        pollIntervalMinutes = Self.defaults.integer(forKey: "pollIntervalMinutes")
        reviveBubble = Self.defaults.bool(forKey: "reviveBubble")
        bubbleMetric = BubbleMetric(rawValue: Self.defaults.string(forKey: "bubbleMetric") ?? "") ?? .session
        useSystemAccent = Self.defaults.bool(forKey: "useSystemAccent")
        launchAtLogin = false
        if canManageLoginItem {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        isLoaded = true
    }

    private func persist(_ value: Any, _ key: String) {
        guard isLoaded else { return }
        Self.defaults.set(value, forKey: key)
    }

    private func updateLoginItem() {
        guard isLoaded, canManageLoginItem else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 失敗したら実際の状態に戻す
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
