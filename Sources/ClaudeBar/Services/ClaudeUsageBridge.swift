import Foundation

/// キーチェーンに一切触れずに使用量を取得する経路。
///
/// Claude Code は `/api/oauth/usage` の結果を `~/.claude.json` の `cachedUsageUtilization` に
/// キャッシュしている。これはただのJSONファイルなので読むのに権限はいらず、macOSの
/// キーチェーン許可ダイアログが出ない。キャッシュが古ければ Claude Code 自身に
/// `claude -p "/usage"` を実行させて更新させる（Claude Code が自分のトークンで取得するので
/// これもダイアログなし・トークン消費なし）。
///
/// 返すJSONは `cachedUsageUtilization.utilization` で、`/api/oauth/usage` 本体と同じ形なので
/// 既存の `UsageParser` でそのまま解釈できる。
enum ClaudeUsageBridge {

    /// 取得できたら utilization JSON（UsageParserが読める形）を返す。取得不能なら nil。
    /// キャッシュが maxAge より古ければ claude を起動して更新を試みてから読み直す。
    static func fetchUtilizationJSON(maxAge: TimeInterval) async -> Data? {
        if let (data, age) = readCache(), age <= maxAge {
            return data // 十分新しい（Claude Code側が更新済み）→ 起動不要
        }
        await refreshViaClaude()
        return readCache()?.data // 更新に失敗しても、古いキャッシュがあれば使う
    }

    // MARK: - キャッシュ読み取り（ダイアログなし）

    private static func readCache() -> (data: Data, age: TimeInterval)? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let raw = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: utilization) else { return nil }
        let fetchedMs = (cached["fetchedAtMs"] as? Double) ?? 0
        let age = Date().timeIntervalSince1970 - fetchedMs / 1000
        return (data, age)
    }

    // MARK: - Claude Codeに更新させる（トークン消費なし・ダイアログなし）

    /// ログインシェル経由で `claude -p "/usage"` を実行し cachedUsageUtilization を更新させる。
    /// ハングに備えて最長15秒で打ち切る。
    private static func refreshViaClaude() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                // --safe-mode: hooks/プラグインをスキップ（認証は正常動作）
                // --no-session-persistence: セッション履歴を汚さない
                process.arguments = ["-lc", "claude --safe-mode -p '/usage' --no-session-persistence"]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                let watchdog = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    // claude未導入など → 呼び出し側がキーチェーン経路へフォールバック
                }
                watchdog.cancel()
                continuation.resume()
            }
        }
    }
}
