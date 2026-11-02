import Foundation

/// 契約プラン名の判定。Claude Code が `~/.claude.json` の `oauthAccount` に保存している
/// 組織タイプとレート制限ティアから、公式の料金ページと同じ名前を決める。
///
/// 2026-10 に旧 Max 20x 相当が Ultra になった（claude.com/pricing）。CLI 2.1.316 の内部値は
/// まだ `claude_max` + `default_claude_max_20x` のままなので、ティアでも Ultra と判定する。
enum ClaudePlan {
    static func displayName(organizationType: String?, rateLimitTier: String?) -> String? {
        guard let type = organizationType?.lowercased(), !type.isEmpty else { return nil }
        let tier = rateLimitTier?.lowercased() ?? ""
        switch type {
        case "claude_max":
            return tier.contains("20x") || tier.contains("ultra") ? "Ultra" : "Max"
        case "claude_ultra": return "Ultra"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        case "claude_free": return "Free"
        default:
            // 未知のプランは接頭辞を外してそのまま出す（アプリ更新前の新プランでも名前が出る）
            guard type.hasPrefix("claude_") else { return nil }
            let name = type.dropFirst("claude_".count).replacingOccurrences(of: "_", with: " ")
            return name.isEmpty ? nil : name.capitalized
        }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: (modified: Date, name: String?)?

    /// 現在のプラン名。ファイル読み取りを伴うのでメインスレッド外から呼ぶ。
    /// ファイルは数百KBあるので、更新日時が変わった時だけ解析する
    static func current() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        cacheLock.lock()
        let cached = cache
        cacheLock.unlock()
        if let cached, cached.modified == modified { return cached.name }

        // ファイルが無い: ログアウトやアンインストール。プラン名を消す
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // 読めない: Claude Code が書き込み中のことがある。見出しのプラン名を消さない
        guard let raw = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return cached?.name
        }
        let account = root["oauthAccount"] as? [String: Any] // 読めて無いならログアウト
        let name = displayName(
            organizationType: account?["organizationType"] as? String,
            rateLimitTier: account?["organizationRateLimitTier"] as? String
        )
        if let modified {
            cacheLock.lock()
            cache = (modified, name)
            cacheLock.unlock()
        }
        return name
    }
}
