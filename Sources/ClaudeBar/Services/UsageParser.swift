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
        struct ScopedShare: Decodable {
            var limitIndex: Int?
            var allowancePercentOfWeekly: Double?
        }
        var limits: [Limit]?
        var weeklyScopedShares: [ScopedShare]?
    }

    static func parse(_ data: Data) throws -> (snapshot: UsageSnapshot, fableLabel: String?) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(OAuthUsageResponse.self, from: data) else {
            throw ParseError()
        }
        var snapshot = UsageSnapshot()
        snapshot.session = sessionWindow(response)
        snapshot.weeklyAll = window(response.sevenDay) ?? limitWindow(response, kind: "weekly_all")

        var fableLabel: String?
        // 新形式: limits[] の weekly_scoped エントリにモデル別の週間上限（Fable/Opus）が入る。
        // 注意: is_active は「有効/無効」ではなく「いま最も逼迫している制限か」の意味
        // （セッションが最逼迫だと weekly_scoped は false になる）。
        // フィルタに使うとFableが消える（2026-08-09に実データで確認済み）
        // weekly_scoped はモデル別とは限らない（scope.surface の枠もある）ので、モデル名のある行だけを
        // 候補にする。複数あれば枠の本来の対象である Fable を優先し、無ければ先頭のモデルを使う
        let modelLimits = response.limits?.filter {
            $0.kind == "weekly_scoped" && $0.percent != nil && $0.scope?.model?.displayName != nil
        } ?? []
        if let scoped = modelLimits.first(where: { $0.scope?.model?.displayName == "Fable" }) ?? modelLimits.first {
            snapshot.weeklyFable = UsageWindow(utilization: scoped.percent ?? 0, resetsAt: date(scoped.resetsAt))
            fableLabel = scoped.scope?.model?.displayName
            // 「週間の利用上限の最大 50%」。limit_index は limits[] 内の位置を指す
            if let index = response.limits?.firstIndex(where: {
                $0.kind == "weekly_scoped" && $0.scope?.model?.displayName == fableLabel
            }) {
                snapshot.weeklyFableAllowancePercent = response.weeklyScopedShares?
                    .first(where: { $0.limitIndex == index })?.allowancePercentOfWeekly
            }
        } else if let opus = window(response.sevenDayOpus) {
            snapshot.weeklyFable = opus
            fableLabel = "Opus"
        }

        // 全部 nil の 200 応答（{} や未知の形式）で正常値を上書きしない
        // 期間枠が無く追加利用だけが有効なアカウントは正常な応答として扱う
        guard snapshot.session != nil || snapshot.weeklyAll != nil || snapshot.weeklyFable != nil
                || response.extraUsage?.isEnabled == true else {
            throw ParseError()
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

    /// セッション（5時間）枠。**nil は「このプランに5時間制限が無い」を意味する**（Ultra の認証済みアカウント等）。
    /// 未使用のセッションは `{utilization: 0, resets_at: null}` で返り、limits[] にも session 行がある（実データ）。
    /// 実物の Ultra の応答は未確認なので、どちらの形でも枠なしと判定する
    private static func sessionWindow(_ response: OAuthUsageResponse) -> UsageWindow? {
        guard let session = window(response.fiveHour) else {
            return limitWindow(response, kind: "session")
        }
        let hasNoSessionRow = response.limits.map { limits in
            !limits.isEmpty && !limits.contains { $0.kind == "session" }
        } ?? false
        if hasNoSessionRow, session.utilization == 0, session.resetsAt == nil { return nil }
        return session
    }

    private static func limitWindow(_ response: OAuthUsageResponse, kind: String) -> UsageWindow? {
        guard let limit = response.limits?.first(where: { $0.kind == kind }), let percent = limit.percent else {
            return nil
        }
        return UsageWindow(utilization: percent, resetsAt: date(limit.resetsAt))
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
