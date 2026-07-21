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
        check(name: "現在のセッション", old: old?.session, new: new.session)
        check(name: "週間制限（すべてのモデル）", old: old?.weeklyAll, new: new.weeklyAll)
        check(name: "週間制限（\(fableLabel)）", old: old?.weeklyFable, new: new.weeklyFable)
    }

    private func check(name: String, old: UsageWindow?, new: UsageWindow?) {
        guard let new else { return }
        for threshold in [80.0, 95.0] {
            let key = "\(name)-\(Int(threshold))-\(new.resetsAt?.timeIntervalSince1970 ?? 0)"
            guard new.utilization >= threshold, !notifiedKeys.contains(key) else { continue }
            notifiedKeys.insert(key)
            // 起動直後（前回値なし）や既に超過していた場合は騒がない
            guard let old, old.utilization < threshold else { continue }

            var body = "現在 \(Int(new.utilization.rounded()))%"
            if let resets = new.resetsAt {
                body += "・リセットは \(UsageGaugeView.resetText(resets))"
            }
            send(title: "\(name)が\(Int(threshold))%を超えました", body: body)
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
