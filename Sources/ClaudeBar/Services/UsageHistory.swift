import Foundation

/// 週間使用量のサンプルを蓄積し、上限到達を予測する
@MainActor
final class UsageHistory {
    struct Sample: Codable {
        var t: Date
        var v: Double
    }

    private static let storageKey = "usageHistory.weekly.v1"
    private var samples: [Sample]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([Sample].self, from: data) {
            samples = decoded
        } else {
            samples = []
        }
    }

    func add(weekly: Double) {
        let now = Date()
        if let last = samples.last {
            // 値が下がった = 週間ウィンドウのリセット → 履歴をクリア
            if weekly < last.v - 0.5 {
                samples.removeAll()
            } else if now.timeIntervalSince(last.t) < 300, abs(weekly - last.v) < 0.01 {
                return // 5分以内かつ変化なしなら記録しない
            }
        }
        samples.append(Sample(t: now, v: weekly))
        if samples.count > 600 {
            samples.removeFirst(samples.count - 600)
        }
        if let data = try? JSONEncoder().encode(samples) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// 直近6時間の消費ペースを最小二乗法で推定し、上限到達時刻を予測する
    func forecast(current: Double?, resetsAt: Date?) -> WeeklyForecast? {
        guard let current else { return nil }
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        let recent = samples.filter { $0.t > cutoff }
        guard recent.count >= 3,
              let first = recent.first, let last = recent.last,
              last.t.timeIntervalSince(first.t) >= 45 * 60 else { return nil }

        let t0 = first.t
        let xs = recent.map { $0.t.timeIntervalSince(t0) / 3600 } // 時間
        let ys = recent.map(\.v)
        let n = Double(xs.count)
        let sx = xs.reduce(0, +)
        let sy = ys.reduce(0, +)
        let sxx = xs.map { $0 * $0 }.reduce(0, +)
        let sxy = zip(xs, ys).map(*).reduce(0, +)
        let denominator = n * sxx - sx * sx
        guard denominator > 0 else { return nil }
        let slope = (n * sxy - sx * sy) / denominator // %/時

        guard slope > 0.2 else { return .safe } // 5%/日未満なら実質安全
        let eta = Date().addingTimeInterval((100 - current) / slope * 3600)
        if let resetsAt, eta >= resetsAt { return .safe }
        return .willHit(eta)
    }
}
