import SwiftUI

struct UsageGaugeView: View {
    let title: String
    let window: UsageWindow?
    var prominent = false

    private var value: Double { window?.utilization ?? 0 }

    private var tint: Color {
        if value >= 95 { return .red }
        if value >= 80 { return .orange }
        return .claudeOrange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: prominent ? 12 : 11.5, weight: prominent ? .semibold : .regular))
                Spacer()
                Text(window == nil ? "–" : "\(Int(value.rounded()))%")
                    .font(.system(size: prominent ? 16 : 12.5, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.4), value: value)
                    .foregroundStyle(window == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [tint.opacity(0.55), tint],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: max(0, geo.size.width * min(value, 100) / 100))
                }
            }
            .frame(height: prominent ? 9 : 6)
            .animation(.easeOut(duration: 0.4), value: value)

            if let resets = window?.resetsAt {
                // 残り時間は1分ごとに更新
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text("リセット: \(Self.resetText(resets))（\(Self.remainText(resets))）")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    static func resetText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = date.timeIntervalSinceNow < 24 * 3600 ? "H:mm" : "M/d H:mm"
        return formatter.string(from: date)
    }

    static func remainText(_ date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours >= 24 {
            let remainderHours = hours % 24
            return remainderHours > 0 ? "あと\(hours / 24)日\(remainderHours)時間" : "あと\(hours / 24)日"
        }
        if hours > 0 { return "あと\(hours)時間\(minutes)分" }
        return "あと\(minutes)分"
    }
}
