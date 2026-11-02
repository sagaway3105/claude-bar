import SwiftUI

struct UsageGaugeView: View {
    let title: String
    let window: UsageWindow?
    var baseTint: Color = .claudeOrange
    /// タイトル直下の補足（公式の「週間の利用上限の最大 50%」）
    var subtitle: String?

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
                Text(window == nil ? "–" : L("panel.percentUsed", Int(value.rounded())))
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

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let resets = window?.resetsAt {
                // 残り時間は1分ごとに更新
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(L("time.withRemaining", Self.resetSentence(resets), Self.remainText(resets)))
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
    /// 書式はテンプレートから現在のロケール向けに組み立てる。`j` はロケールの優先する
    /// 時刻表記で、日本語なら "15:45"、英語(US)なら "3:45 PM" になる
    /// （`H` は 24 時間表記に固定されるので使わない）
    private static let timeFormatter: DateFormatter = makeFormatter("jm")
    private static let dayTimeFormatter: DateFormatter = makeFormatter("Mdjm")
    private static let weekdayFormatter: DateFormatter = makeFormatter("EEEE")

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

    /// リセット時刻は最も近い分へ丸める。API は 00:59:59.9 のように返すので、
    /// 切り捨てると公式画面の 10:00 に対して 9:59 と出てしまう
    static func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded() * 60)
    }

    static func resetText(_ date: Date) -> String {
        let formatter = date.timeIntervalSinceNow < 24 * 3600 ? timeFormatter : dayTimeFormatter
        return formatter.string(from: roundedToMinute(date))
    }

    /// 現在時刻などの丸めない時刻表示
    static func clockText(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// 最終更新の表示。オフライン中の古いキャッシュが今日のものに見えないよう、今日以外は日付も出す
    static func updatedClockText(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? clockText(date) : dayTimeFormatter.string(from: date)
    }

    /// 公式画面と同じ言い回し（「20:10にリセットされます」「10:00 (木曜日)にリセット」）
    static func resetSentence(_ date: Date) -> String {
        let rounded = roundedToMinute(date)
        let time = timeFormatter.string(from: rounded)
        if date.timeIntervalSinceNow < 24 * 3600 {
            return L("time.resetsToday", time)
        }
        return L("time.resetsOnDay", time, weekdayFormatter.string(from: rounded))
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
