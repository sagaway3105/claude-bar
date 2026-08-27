import Foundation
import UserNotifications

/// しきい値（80%/95%）を跨いだ時に通知センターへ通知する
@MainActor
final class NotificationService {
    private var notifiedKeys: Set<String> = []
    private var authRequested = false

    /// UNUserNotificationCenterは.appバンドルからの起動でのみ動作する
    let canNotify = Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"

    func evaluate(old: UsageSnapshot?, new: UsageSnapshot, fableLabel: String, enabled: Bool) {
        guard enabled, canNotify else { return }
        check(name: L("notify.currentSession"), old: old?.session, new: new.session)
        check(name: L("notify.weeklyAllModels"), old: old?.weeklyAll, new: new.weeklyAll)
        check(name: L("notify.weeklyModel", fableLabel), old: old?.weeklyFable, new: new.weeklyFable)
    }

    private func check(name: String, old: UsageWindow?, new: UsageWindow?) {
        guard let new else { return }
        for threshold in [80.0, 95.0] {
            let key = "\(name)-\(Int(threshold))-\(new.resetsAt?.timeIntervalSince1970 ?? 0)"
            guard new.utilization >= threshold, !notifiedKeys.contains(key) else { continue }
            // resetsAt不明のままキーを恒久登録すると、リセット後に再度跨いでも二度と
            // 通知されない。期間を特定できる時だけ記録し、不明時は閾値跨ぎ判定だけで抑制する
            if new.resetsAt != nil { notifiedKeys.insert(key) }
            // 起動直後（前回値なし）や既に超過していた場合は騒がない
            guard let old, old.utilization < threshold else { continue }

            var body = L("notify.currentPercent", Int(new.utilization.rounded()))
            if let resets = new.resetsAt {
                body += L("notify.resetsAt", UsageGaugeView.resetText(resets))
            }
            send(title: L("notify.thresholdTitle", name, Int(threshold)), body: body)
        }
    }

    private func send(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            )
            center.add(request)
        }
        if authRequested {
            deliver()
        } else {
            authRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { deliver() }
            }
        }
    }
}
