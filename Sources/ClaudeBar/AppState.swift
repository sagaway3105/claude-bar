import Foundation
import Observation

struct UsageWindow {
    var utilization: Double // 0...100 のパーセント値
    var resetsAt: Date?
}

struct ExtraUsage {
    var isEnabled: Bool
    var utilization: Double?
    var usedCredits: Double?
    var monthlyLimit: Double?
    var currency: String?
}

struct UsageSnapshot {
    var session: UsageWindow?     // five_hour
    var weeklyAll: UsageWindow?   // seven_day
    var weeklyFable: UsageWindow? // limits[] weekly_scoped または seven_day_opus
    var weeklyFableAllowancePercent: Double? // 週間上限に対するモデル枠の割合（公式の「最大 50%」）
    var extra: ExtraUsage?
}

extension UsageSnapshot {
    /// リセット時刻を過ぎた枠を「新しい期間の 0%」として扱う（古いキャッシュ向け）
    var hasNoWindows: Bool { session == nil && weeklyAll == nil && weeklyFable == nil }

    /// 枠のある表示を、枠の全く無い応答で置き換えない（一時的に欠けた応答で 0% に見せない）。
    /// 期間枠の無いプランは最初から枠が無いので、通常どおり表示できる
    func canReplace(_ current: UsageSnapshot?) -> Bool {
        !hasNoWindows || current?.hasNoWindows != false
    }

    func hasExpiredWindows(now: Date = Date()) -> Bool {
        [session, weeklyAll, weeklyFable].contains { window in
            guard let resets = window?.resetsAt else { return false }
            return resets <= now
        }
    }

    func clearingExpiredWindows(now: Date = Date()) -> UsageSnapshot {
        func clear(_ window: UsageWindow?) -> UsageWindow? {
            guard let window, let resets = window.resetsAt, resets <= now else { return window }
            return UsageWindow(utilization: 0, resetsAt: nil)
        }
        var copy = self
        copy.session = clear(session)
        copy.weeklyAll = clear(weeklyAll)
        copy.weeklyFable = clear(weeklyFable)
        return copy
    }

    func window(for metric: BubbleMetric) -> UsageWindow? {
        switch metric {
        case .session: return session
        case .weekly: return weeklyAll
        case .fable: return weeklyFable
        }
    }
}

enum PanelMode {
    case attached // メニューバー直下のパネル
    case floating // 引き剥がした（またはバブルから展開した）フローティングパネル
}

@MainActor
@Observable
final class AppState {
    var usage: UsageSnapshot?
    var lastUpdated: Date?
    var errorMessage: String?

    /// 認証情報が無い/期限切れなどで、ログイン導線を出すべき状態
    var needsLogin = false

    /// attachedパネルが開いている間、メニューバーのハイライトを点灯
    var menuHighlighted = false

    /// Claude Codeがトークンを消費中かどうか（ロゴアニメーション用）
    var isActive = false

    var mode: PanelMode = .attached

    /// バブル（浮遊モード）が表示中か。パネルとは独立に共存できる
    var bubbleActive = false

    /// 背景追従が実際に測れていて、球の外観が背景に合っているか
    var backdropLive = false

    /// limits[] の scope.model.display_name から動的に決まる（"Fable" / "Opus"）
    var fableLabel = "Fable"

    /// 契約プラン名（Max / Ultra など）。取得できなければ nil で表示しない
    var planName: String?

    /// プランに無い枠が選ばれていたら週間へ切り替える（例: 5時間制限の無いプランのセッション）
    func effectiveMetric(_ metric: BubbleMetric) -> BubbleMetric {
        guard let usage, usage.window(for: metric) == nil, usage.weeklyAll != nil else { return metric }
        return .weekly
    }

    /// 使用量を取得済みで、その枠がプランに無い
    func isMetricAbsent(_ metric: BubbleMetric) -> Bool {
        guard let usage else { return false }
        return usage.window(for: metric) == nil
    }

    private var lastActivityAt: Date = .distantPast
    private var idleTask: Task<Void, Never>?
    private let idleThreshold: TimeInterval = 6

    /// メニューバーに出す使用率。セッション枠の無いプランでは週間を出す
    var menuBarUtilization: Double? {
        guard let usage else { return nil }
        return usage.session?.utilization ?? usage.weeklyAll?.utilization ?? 0
    }

    var menuBarPercentText: String {
        guard let u = menuBarUtilization else { return "–%" }
        return "\(Int(u.rounded()))%"
    }

    func registerActivity() {
        lastActivityAt = Date()
        if !isActive { isActive = true }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(idleThreshold))
            guard !Task.isCancelled else { return }
            if Date().timeIntervalSince(self.lastActivityAt) >= self.idleThreshold - 0.5 {
                self.isActive = false
            }
        }
    }
}
