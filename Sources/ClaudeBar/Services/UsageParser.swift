import Foundation

/// /api/oauth/usage のレスポンスをUsageSnapshotへ変換する（テスト可能な純粋関数）
enum UsageParser {
    struct ParseError: Error {}

    private struct OAuthUsageResponse: Decodable {
        struct Window: Decodable {
            var utilization: Double? // 0-100のパーセント値
            var resetsAt: String?
        }
        struct ExtraUsagePayload: Decodable {
            var isEnabled: Bool?
            var utilization: Double?
            var usedCredits: Double?
            var monthlyLimit: Double?
            var currency: String?
        }
        struct Limit: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable {
                    var id: String?
                    var displayName: String?
                }
                var model: Model?
            }
            var kind: String?
            var percent: Double?
            var resetsAt: String?
            var isActive: Bool?
            var scope: Scope?
        }
        var fiveHour: Window?
        var sevenDay: Window?
        var sevenDayOpus: Window?
        var extraUsage: ExtraUsagePayload?
        var limits: [Limit]?
    }

    static func parse(_ data: Data) throws -> (snapshot: UsageSnapshot, fableLabel: String?) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(OAuthUsageResponse.self, from: data) else {
            throw ParseError()
        }
        var snapshot = UsageSnapshot()
        snapshot.session = window(response.fiveHour)
        snapshot.weeklyAll = window(response.sevenDay)

        var fableLabel: String?
        // 新形式: limits[] の weekly_scoped エントリにモデル別の週間上限（Fable/Opus）が入る
        if let scoped = response.limits?.first(where: { $0.kind == "weekly_scoped" && $0.percent != nil }) {
            snapshot.weeklyFable = UsageWindow(utilization: scoped.percent ?? 0, resetsAt: date(scoped.resetsAt))
            fableLabel = scoped.scope?.model?.displayName
        } else if let opus = window(response.sevenDayOpus) {
            snapshot.weeklyFable = opus
            fableLabel = "Opus"
        }

        if let extra = response.extraUsage {
            snapshot.extra = ExtraUsage(
                isEnabled: extra.isEnabled ?? false,
                utilization: extra.utilization,
                usedCredits: extra.usedCredits,
                monthlyLimit: extra.monthlyLimit,
                currency: extra.currency
            )
        }
        return (snapshot, fableLabel)
    }

    private static func window(_ w: OAuthUsageResponse.Window?) -> UsageWindow? {
        guard let w, let u = w.utilization else { return nil }
        return UsageWindow(utilization: u, resetsAt: date(w.resetsAt))
    }

    static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: iso) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }
}
