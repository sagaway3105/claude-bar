import Foundation

/// 使用量ウィンドウが新しい期間へ進んだかの判定（テスト可能な純粋関数）。
///
/// API は未使用のセッションで `five_hour.resets_at: null` を返す（2026-11-01 実データで確認）。
/// つまりリセット後に使い始めていなければ「次のリセット時刻」は来ないので、
/// **控えていた時刻を過ぎたうえで現在値が null なら、リセット済みとして扱う**。
enum UsageResetDetector {
    /// リセット時刻の秒単位の揺れを新しい期間と誤認しないための遊び
    static let tolerance: TimeInterval = 60

    /// - Parameters:
    ///   - previous: 前回控えたリセット時刻
    ///   - current: 今回取得したリセット時刻（未使用のセッションでは nil）
    static func hasReset(previous: Date, current: Date?, now: Date = Date()) -> Bool {
        // 控えた時刻がまだ十分先なら、値が変わっても一時的な揺れや欠損とみなす
        guard previous.timeIntervalSince(now) < tolerance else { return false }
        guard let current else { return true }
        return current > previous.addingTimeInterval(tolerance)
    }
}
