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
            return L("error.auth401")
        case .forbidden:
            return L("error.forbidden403")
        case .rateLimited(let until):
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("jm") // ロケール準拠（英語圏は 3:45 PM）
            return L("error.rateLimited", f.string(from: until))
        case .http(let code):
            return L("error.httpFailed", code)
        case .badResponse:
            return L("error.badResponse")
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
    private var pendingForce = false // refresh進行中に来た手動更新の保留フラグ
    /// 最後に取得を試みた時刻。失敗中は lastUpdated が進まないので、抑制はこちらで判定する
    private var lastAttemptAt: Date = .distantPast
    /// claude を最後に起動した時刻。失敗が続いても起動し続けないようにする
    private var lastCLIRefreshAt: Date = .distantPast
    private let cliRefreshMinInterval: TimeInterval = 300

    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session = UsageService.makeTokenSession()
    private var windowlessResponses = 0

    /// トークンを送るリクエスト専用のセッション。URLSession.shared はリクエストごと
    /// Authorization ヘッダをディスクのキャッシュへ残す（v1.6.1 の Cache.db で確認）。
    /// リダイレクトにも従わず、トークンを固定のエンドポイント以外へ送らない
    nonisolated static func makeTokenSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
    private let rateLimitCooldown: TimeInterval = 300

    #if DEBUG
    /// UIテスト用: ネットワークに触らずデバッグ注入だけを受け付ける（デバッグビルド限定）
    private let isFake = ProcessInfo.processInfo.environment["CLAUDEBAR_FAKE"] == "1"
    #else
    private let isFake = false
    #endif

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
            while !Task.isCancelled {
                await refresh()
                // 設定の更新間隔変更が数秒で効くよう、目標時間まで短い刻みで待つ
                var waited: TimeInterval = 0
                while !Task.isCancelled {
                    let target = TimeInterval(max(1, settings.pollIntervalMinutes) * 60)
                    if waited >= target { break }
                    let step = min(10, target - waited)
                    // 許容幅を付けて他の処理と起床をまとめる（精度は要らない）
                    try? await Task.sleep(for: .seconds(step), tolerance: .seconds(2))
                    waited += step
                }
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
        // API 障害中に、JSONL の書き込みのたびに連打しない
        guard Date().timeIntervalSince(lastAttemptAt) >= seconds else { return }
        Task { await refresh() }
    }

    /// force: 手動更新（↻・右クリック）。フォールバック経路の鮮度判定を厳しくする
    func refresh(force: Bool = false) async {
        guard !isFake else { return }
        if isRefreshing {
            // 進行中に来た手動更新は黙って捨てず、完了後に改めて実行する
            if force { pendingForce = true }
            return
        }
        isRefreshing = true
        lastAttemptAt = Date()
        defer {
            isRefreshing = false
            if pendingForce {
                pendingForce = false
                Task { await self.refresh(force: true) }
            }
        }

        // プラン変更にも追従する（ファイル読み取りなのでメインスレッドを塞がない）
        state.planName = await Task.detached { ClaudePlan.current() }.value

        // 主経路: API直叩き（トークンはsecurity CLI経由＝ダイアログなし）。
        // サーバーの現在値がそのまま来るので、設定した更新間隔どおりの鮮度になる
        if await refreshViaKeychainAPI() { return }
        // 呼び出し元の取り消しなら、claude を起動するフォールバックへ進まない
        if Task.isCancelled { return }

        // フォールバック: Claude Codeのローカルキャッシュ+claude起動
        // （オフライン・レート制限クールダウン中・トークン不在などのケース）
        let maxAge: TimeInterval = force ? 15 : TimeInterval(max(1, settings.pollIntervalMinutes) * 60)
        let allowCLI = force || Date().timeIntervalSince(lastCLIRefreshAt) >= cliRefreshMinInterval
        let fetched = await ClaudeUsageBridge.fetchUtilizationJSON(maxAge: maxAge, allowCLIRefresh: allowCLI)
        if fetched.ranCLI { lastCLIRefreshAt = Date() }
        if let usage = fetched.usage, let parsed = try? UsageParser.parse(usage.data) {
            // キャッシュは古いことがある。リセット時刻を過ぎた枠の値は信用しない
            apply(parsed.snapshot.clearingExpiredWindows(), fableLabel: parsed.fableLabel, asOf: usage.fetchedAt)
        }
        clearExpiredWindowsInDisplayedUsage()
    }

    /// 取得できない間にリセット時刻を過ぎた枠を、表示からも消す。キャッシュが無い時や、
    /// 表示中より古いキャッシュを apply が弾いた時も、古い使用率を出し続けない
    private func clearExpiredWindowsInDisplayedUsage() {
        guard let usage = state.usage, usage.hasExpiredWindows() else { return }
        state.usage = usage.clearingExpiredWindows()
        onUsageApplied?() // バブルのリセット検知と復活へ伝える
    }

    /// API直叩き（主経路）。成功して適用できたらtrue。
    /// 失敗時はエラー状態を設定してfalseを返す（フォールバックが成功すればapplyが上書きする）
    private func refreshViaKeychainAPI() async -> Bool {
        if let until = cooldownUntil, until > Date() { return false }
        await detectCLIVersionIfNeeded()
        do {
            // securityサブプロセス（最長3秒）でメインスレッドを塞がない
            let creds = try await Task.detached { try CredentialsStore.load() }.value
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 30
            request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-code/\(cliVersion)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UsageError.badResponse }
            switch http.statusCode {
            case 200:
                let (snapshot, fableLabel) = try UsageParser.parse(data)
                cooldownUntil = nil
                apply(snapshot, fableLabel: fableLabel)
                return true
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
        } catch is CancellationError {
            // バブルの操作で呼び出し元のタスクが取り消されただけ。障害として表示しない
        } catch let error as URLError where error.code == .cancelled {
            // 同上
        } catch {
            state.errorMessage = error.localizedDescription
        }
        return false
    }

    /// asOf: データの実際の取得時刻（キャッシュ由来の場合は過去になる。「◯時◯分 更新」表示を正直に保つ）
    func apply(_ snapshot: UsageSnapshot, fableLabel: String?, asOf: Date = Date()) {
        // 適用済みより明確に古いデータでは上書きしない。フォールバックが期限切れキャッシュを
        // 返した時に表示が過去へ巻き戻り、直前の障害メッセージまで消えるのを防ぐ。
        // 同一キャッシュの再適用（asOfがほぼ同時刻）は通す — needsLogin/エラー表示のクリアを
        // 担っており、弾くとローカル経路運用でログイン導線が誤表示され続ける
        if let last = state.lastUpdated, asOf.timeIntervalSince(last) < -1.0 { return }
        // 枠の無い応答は一時的な欠けとして無視する。続くなら本当に枠の無いプランへ変わったので受け入れる
        if snapshot.canReplace(state.usage) {
            windowlessResponses = 0
        } else {
            windowlessResponses += 1
            if windowlessResponses < 3 { return }
            windowlessResponses = 0
        }
        let old = state.usage
        state.usage = snapshot
        if let fableLabel { state.fableLabel = fableLabel }
        state.lastUpdated = asOf
        state.errorMessage = nil
        state.needsLogin = false

        notifier.evaluate(
            old: old, new: snapshot,
            fableLabel: state.fableLabel,
            enabled: settings.notifyThresholds
        )
        onUsageApplied?()
    }

    #if DEBUG
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
    #endif

    // MARK: - Claude CLIバージョン検出（フォールバックAPIのUser-Agent用）

    private var didDetectCLIVersion = false

    /// User-Agent 用に、起動後の最初の更新で一度だけ検出する。バイナリ直接起動
    /// （ログインシェル経由は.zshrc走査がTCC確認を誘発するため使わない）
    private func detectCLIVersionIfNeeded() async {
        guard !didDetectCLIVersion, !isFake,
              let claudePath = ClaudeUsageBridge.claudeBinaryPath() else { return }
        didDetectCLIVersion = true
        let version: String? = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                // ハングする実体（壊れたshim等）でrefresh全体が永久停止しないよう、
                // 他のサブプロセス（security 3秒 / claude 15秒）と同じウォッチドッグを付ける
                let watchdog = DispatchWorkItem {
                    guard process.isRunning else { return }
                    process.terminate()
                    // SIGTERMを無視する実体への保険
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)
                process.waitUntilExit()
                watchdog.cancel()
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
