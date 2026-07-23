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

    /// 取得できたら utilization JSON（UsageParserが読める形）と実際の取得時刻を返す。取得不能なら nil。
    /// キャッシュが maxAge より古ければ claude を起動して更新を試みてから読み直す。
    static func fetchUtilizationJSON(maxAge: TimeInterval) async -> (data: Data, fetchedAt: Date)? {
        if let cached = readCache(), cached.age <= maxAge {
            return (cached.data, Date().addingTimeInterval(-cached.age)) // 十分新しい → 起動不要
        }
        await refreshViaClaude()
        // 更新に失敗しても古いキャッシュがあれば使う（取得時刻は正直に返し、UIの「更新」表示に反映させる）
        guard let cached = readCache() else { return nil }
        return (cached.data, Date().addingTimeInterval(-cached.age))
    }

    /// claude バイナリの実体パス（既知の配置場所を直接探す。ログインシェルは使わない）。
    /// ログインシェル(.zshrc)経由だとフォルダ/リムーバブルディスクのTCC確認が出るため直接叩く。
    /// CLI検出（LoginHelper）と実行（本ブリッジ・バージョン検出）で共有する唯一の探索ロジック。
    static func claudeBinaryPath() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
            home + "/.npm-global/bin/claude",
            home + "/.volta/bin/claude",
            home + "/.asdf/shims/claude",
        ]
        // nvm: バージョンディレクトリ配下を走査（新しい順）
        let nvmRoot = home + "/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot) {
            candidates += versions.sorted(by: >).map { "\(nvmRoot)/\($0)/bin/claude" }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
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

    /// claude バイナリを直接実行して `/usage` を走らせ cachedUsageUtilization を更新させる。
    /// ハングに備えて最長15秒で打ち切る。作業ディレクトリはホーム直下（保護対象外）にして
    /// Desktop/Documents/リムーバブルディスク等のTCC確認を誘発しないようにする。
    private static func refreshViaClaude() async {
        guard let claudePath = claudeBinaryPath() else { return } // 未検出→キーチェーン経路へ
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: claudePath)
                // --safe-mode: hooks/プラグインをスキップ（認証は正常動作）
                // --no-session-persistence: セッション履歴を汚さない
                process.arguments = ["--safe-mode", "-p", "/usage", "--no-session-persistence"]
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
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
                    // 実行失敗 → 呼び出し側がキーチェーン経路へフォールバック
                }
                watchdog.cancel()
                continuation.resume()
            }
        }
    }
}
