import SwiftUI

struct UsageGaugeView: View {
    let title: String
    let window: UsageWindow?
    var baseTint: Color = .claudeOrange

    private var value: Double { window?.utilization ?? 0 }

    private var tint: Color {
        if value >= 95 { return .red }
        if value >= 80 { return .orange }
        return baseTint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                Text(window == nil ? "–" : "\(Int(value.rounded()))%")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.4), value: value)
                    // 数字は標準の文字色（色はバー側で表現する）
                    .foregroundStyle(window == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [tint.opacity(0.55), tint],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: max(0, geo.size.width * min(value, 100) / 100))
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.4), value: value)

            if let resets = window?.resetsAt {
                // 残り時間は1分ごとに更新
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(L("time.resetsIn", Self.resetText(resets), Self.remainText(resets)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// DateFormatterの生成はICUフォーマッタ構築を伴い高価（毎フレーム呼ぶと
    /// バブルのフレームコストの約半分を占めた実測あり）なので、2書式とも使い回す。
    /// dateFormatの切替も内部再構築を誘発するため、書式ごとに別インスタンスを持つ。
    ///
    /// 書式はテンプレートから現在のロケール向けに組み立てる（`Hm` は
    /// 日本語なら "15:45"、英語(US)なら "3:45 PM" になる）。固定の "H:mm" を
    /// 使うと英語圏で24時間表記が出てしまう
    private static let timeFormatter: DateFormatter = makeFormatter("Hm")
    private static let dayTimeFormatter: DateFormatter = makeFormatter("MdHm")

    private static func makeFormatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        let locale = Locale.autoupdatingCurrent
        formatter.locale = locale
        // キャッシュされた後もシステムのタイムゾーン変更に追従させる
        // （既定値だと生成時点のゾーンで固定され、旅行やDST切替で時刻がズレる）
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    static func resetText(_ date: Date) -> String {
        let formatter = date.timeIntervalSinceNow < 24 * 3600 ? timeFormatter : dayTimeFormatter
        return formatter.string(from: date)
    }

    static func remainText(_ date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours >= 24 {
            let remainderHours = hours % 24
            return remainderHours > 0
                ? L("time.daysHours", hours / 24, remainderHours)
                : L("time.days", hours / 24)
        }
        if hours > 0 { return L("time.hoursMinutes", hours, minutes) }
        return L("time.minutes", minutes)
    }
}
