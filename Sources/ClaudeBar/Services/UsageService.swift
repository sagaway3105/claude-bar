import AppKit
import Foundation

enum UsageError: LocalizedError {
    case unauthorized
    case forbidden
    case rateLimited(until: Date)
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "認証エラー(401)。Claude Codeを一度使うとトークンが更新されます。"
        case .forbidden:
            return "権限エラー(403)。トークンのスコープが不足しています。"
        case .rateLimited(let until):
            let f = DateFormatter()
            f.dateFormat = "H:mm"
            return "レート制限中。\(f.string(from: until)) 以降に自動で再試行します。"
        case .http(let code):
            return "使用量の取得に失敗しました (HTTP \(code))"
        case .badResponse:
            return "使用量レスポンスを解釈できませんでした。"
        }
    }
}

@MainActor
final class UsageService {
    private let state: AppState
    private let settings: SettingsStore
    private let notifier: NotificationService

    /// 使用量スナップショット適用後に呼ばれる（バブルのリセット破裂検知フック）
    var onUsageApplied: (() -> Void)?
    private var pollTask: Task<Void, Never>?
    private var cooldownUntil: Date?
    private var isRefreshing = false

    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let rateLimitCooldown: TimeInterval = 300

    /// UIテスト用: ネットワークに触らずデバッグ注入だけを受け付ける
    private let isFake = ProcessInfo.processInfo.environment["CLAUDEBAR_FAKE"] == "1"

    /// User-Agent用。claude-code/<version> を送らないと厳しいレート制限バケットに入る
    private var cliVersion = "2.1.0"

    init(state: AppState, settings: SettingsStore, notifier: NotificationService) {
        self.state = state
        self.settings = settings
        self.notifier = notifier
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            await detectCLIVersion()
            while !Task.isCancelled {
                await refresh()
                let minutes = max(1, settings.pollIntervalMinutes)
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refreshIfStale(olderThan seconds: TimeInterval) {
        if let last = state.lastUpdated, Date().timeIntervalSince(last) < seconds { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isFake, !isRefreshing else { return }
        if let until = cooldownUntil, until > Date() { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // 主経路: キーチェーンに触れずローカルキャッシュ+claudeで取得（ダイアログが出ない）。
        // キャッシュが更新間隔より古ければ claude -p "/usage" で更新させる。
        let maxAge = TimeInterval(max(1, settings.pollIntervalMinutes) * 60)
        if let data = await ClaudeUsageBridge.fetchUtilizationJSON(maxAge: maxAge),
           let parsed = try? UsageParser.parse(data) {
            apply(parsed.snapshot, fableLabel: parsed.fableLabel)
            return
        }
        // フォールバック: 従来のキーチェーン+API（claude未導入・未ログインなどのレアケース）
        await refreshViaKeychainAPI()
    }

    private func refreshViaKeychainAPI() async {
        do {
            let creds = try CredentialsStore.load()
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 30
            request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-code/\(cliVersion)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UsageError.badResponse }
            switch http.statusCode {
            case 200:
                let (snapshot, fableLabel) = try UsageParser.parse(data)
                apply(snapshot, fableLabel: fableLabel)
            case 401:
                throw UsageError.unauthorized
            case 403:
                throw UsageError.forbidden
            case 429:
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let until = Date().addingTimeInterval(retryAfter ?? rateLimitCooldown)
                cooldownUntil = until
                throw UsageError.rateLimited(until: until)
            default:
                throw UsageError.http(http.statusCode)
            }
        } catch let error as UsageParser.ParseError {
            _ = error
            state.errorMessage = UsageError.badResponse.localizedDescription
        } catch let error as CredentialsError {
            state.errorMessage = error.localizedDescription
            switch error {
            case .notFound, .mcpOnly, .missingProfileScope:
                state.needsLogin = true
            case .expired, .unreadable:
                // 連携済みでも起きる一時状態。連携タイルではなく一行メッセージに留める
                break
            }
        } catch let error as UsageError {
            state.errorMessage = error.localizedDescription
            switch error {
            case .forbidden:
                state.needsLogin = true
            case .unauthorized:
                // キャッシュ済みトークンが拒否された → 次回ポーリングで元項目を読み直す
                CredentialsStore.invalidateCache()
            default:
                break
            }
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    func apply(_ snapshot: UsageSnapshot, fableLabel: String?) {
        let old = state.usage
        state.usage = snapshot
        if let fableLabel { state.fableLabel = fableLabel }
        state.lastUpdated = Date()
        state.errorMessage = nil
        state.needsLogin = false
        cooldownUntil = nil

        notifier.evaluate(
            old: old, new: snapshot,
            fableLabel: state.fableLabel,
            enabled: settings.notifyThresholds
        )
        onUsageApplied?()
    }

    /// デバッグ注入（CLAUDEBAR_FAKE=1でのUI検証用）
    func applyFake(session: Double?, weekly: Double?, fable: Double?) {
        var snapshot = UsageSnapshot()
        if let session {
            snapshot.session = UsageWindow(utilization: session, resetsAt: Date().addingTimeInterval(2 * 3600 + 840))
        }
        if let weekly {
            snapshot.weeklyAll = UsageWindow(utilization: weekly, resetsAt: Date().addingTimeInterval(3 * 86400 + 7200))
        }
        if let fable {
            snapshot.weeklyFable = UsageWindow(utilization: fable, resetsAt: Date().addingTimeInterval(3 * 86400 + 7200))
        }
        apply(snapshot, fableLabel: nil)
    }

    // MARK: - Claude CLIバージョン検出（User-Agent用）

    private func detectCLIVersion() async {
        guard !isFake else { return }
        let version: String? = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "claude --version 2>/dev/null"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8) else { return nil }
                // 例: "2.1.34 (Claude Code)" → "2.1.34"
                if let match = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
                    return String(output[match])
                }
            } catch {}
            return nil
        }.value
        if let version { cliVersion = version }
    }
}
