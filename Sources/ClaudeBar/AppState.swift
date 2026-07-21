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
    var extra: ExtraUsage?
}

extension UsageSnapshot {
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
    case bubble   // ぷかぷか浮遊するバブル
    case floating // バブルから展開したフローティングパネル
}

enum WeeklyForecast: Equatable {
    case safe
    case willHit(Date)
}

@MainActor
@Observable
final class AppState {
    var usage: UsageSnapshot?
    var lastUpdated: Date?
    var errorMessage: String?
    var weeklyForecast: WeeklyForecast?

    /// 認証情報が無い/期限切れなどで、ログイン導線を出すべき状態
    var needsLogin = false

    /// Claude Codeがトークンを消費中かどうか（ロゴアニメーション用）
    var isActive = false

    var mode: PanelMode = .attached

    // 「ぷるんっ/ポヨン」はPanelController.bounceAssembly()（レイヤー変形）で行う

    /// limits[] の scope.model.display_name から動的に決まる（"Fable" / "Opus"）
    var fableLabel = "Fable"

    private var lastActivityAt: Date = .distantPast
    private var idleTask: Task<Void, Never>?
    private let idleThreshold: TimeInterval = 6

    var sessionUtilization: Double? {
        guard usage != nil else { return nil }
        return usage?.session?.utilization ?? 0
    }

    var sessionPercentText: String {
        guard let u = sessionUtilization else { return "–%" }
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
