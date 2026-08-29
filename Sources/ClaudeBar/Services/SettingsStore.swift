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

    /// 破裂音を鳴らすか（見た目の演出は鳴らさなくても行う）
    var popSound: Bool {
        didSet { persist(popSound, "popSound") }
    }

    var bubbleMetric: BubbleMetric {
        didSet { persist(bubbleMetric.rawValue, "bubbleMetric") }
    }

    /// バブル表示個数の変更時に呼ばれる（表示中のバブルを新モードで組み直すため）
    var onBubbleCountChanged: (() -> Void)?

    /// バブルの表示個数。3ならセッション+Fable+週間を同時に浮かべる（bubbleMetricは無効）
    var bubbleCount: Int {
        didSet {
            persist(bubbleCount, "bubbleCount")
            if isLoaded, oldValue != bubbleCount { onBubbleCountChanged?() }
        }
    }

    /// 3つ表示モードか
    var isTripleBubble: Bool { bubbleCount == 3 }

    /// バーの色をmacOSのアクセントカラーに合わせる（falseならClaudeオレンジ）
    var useSystemAccent: Bool {
        didSet { persist(useSystemAccent, "useSystemAccent") }
    }

    /// アップデートを自動で確認する（Sparkle）
    var autoUpdate: Bool {
        didSet { persist(autoUpdate, "autoUpdate") }
    }

    var launchAtLogin: Bool {
        didSet { updateLoginItem() }
    }

    init() {
        Self.defaults.register(defaults: [
            "notifyThresholds": true,
            "pollIntervalMinutes": 2,
            "reviveBubble": true,
            "popSound": true,
            "bubbleMetric": BubbleMetric.session.rawValue,
            "bubbleCount": 1,
            "useSystemAccent": true,
            "autoUpdate": true,
        ])
        notifyThresholds = Self.defaults.bool(forKey: "notifyThresholds")
        pollIntervalMinutes = Self.defaults.integer(forKey: "pollIntervalMinutes")
        reviveBubble = Self.defaults.bool(forKey: "reviveBubble")
        popSound = Self.defaults.bool(forKey: "popSound")
        bubbleMetric = BubbleMetric(rawValue: Self.defaults.string(forKey: "bubbleMetric") ?? "") ?? .session
        bubbleCount = Self.defaults.integer(forKey: "bubbleCount") == 3 ? 3 : 1
        useSystemAccent = Self.defaults.bool(forKey: "useSystemAccent")
        autoUpdate = Self.defaults.bool(forKey: "autoUpdate")
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

    /// didSetから呼んだメソッド内の再代入は（observer本体と違い）didSetを再発火させるため、
    /// catch節の巻き戻しからの再帰をこのフラグで止める。register/unregisterが
    /// 連続してthrowする環境（App Translocation下等）で無限再帰になるのを防ぐ
    private var isSyncingLoginItem = false

    private func updateLoginItem() {
        guard isLoaded, canManageLoginItem, !isSyncingLoginItem else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 失敗したら実際の状態に戻す
            isSyncingLoginItem = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            isSyncingLoginItem = false
        }
    }
}
