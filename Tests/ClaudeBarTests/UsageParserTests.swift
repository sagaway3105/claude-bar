import XCTest
@testable import ClaudeBar

final class UsageParserTests: XCTestCase {

    // 実際のAPIレスポンス例（Claude-Code-Usage-Monitor issue #202 より）
    func testParseRealWorldResponse() throws {
        let json = """
        {
            "five_hour": {
                "utilization": 33.0,
                "resets_at": "2026-04-11T07:00:00.528743+00:00"
            },
            "seven_day": {
                "utilization": 13.0,
                "resets_at": "2026-04-17T00:59:59.951713+00:00"
            },
            "seven_day_opus": null,
            "seven_day_sonnet": {
                "utilization": 1.0,
                "resets_at": "2026-04-16T03:00:00.951719+00:00"
            },
            "extra_usage": {
                "is_enabled": false,
                "monthly_limit": null,
                "used_credits": null,
                "utilization": null
            }
        }
        """.data(using: .utf8)!

        let (snapshot, fableLabel) = try UsageParser.parse(json)
        XCTAssertEqual(snapshot.session?.utilization, 33.0)
        XCTAssertEqual(snapshot.weeklyAll?.utilization, 13.0)
        XCTAssertNotNil(snapshot.session?.resetsAt)
        // opusがnull・limitsなし → Fable枠は無し
        XCTAssertNil(snapshot.weeklyFable)
        XCTAssertNil(fableLabel)
        XCTAssertEqual(snapshot.extra?.isEnabled, false)
    }

    // 新形式: limits[] の weekly_scoped から Fable のラベルと%を取る
    func testParseLimitsArrayWithFable() throws {
        let json = """
        {
            "five_hour": { "utilization": 61.5, "resets_at": "2026-07-22T09:00:00+00:00" },
            "seven_day": { "utilization": 41.0, "resets_at": "2026-07-25T00:59:59+00:00" },
            "seven_day_opus": null,
            "limits": [
                {
                    "kind": "weekly_scoped",
                    "group": "weekly",
                    "percent": 12.0,
                    "resets_at": "2026-07-25T00:59:59+00:00",
                    "is_active": true,
                    "scope": { "model": { "id": "claude-fable-5", "display_name": "Fable" } }
                }
            ]
        }
        """.data(using: .utf8)!

        let (snapshot, fableLabel) = try UsageParser.parse(json)
        XCTAssertEqual(snapshot.session?.utilization, 61.5)
        XCTAssertEqual(snapshot.weeklyFable?.utilization, 12.0)
        XCTAssertEqual(fableLabel, "Fable")
    }

    // 旧形式: seven_day_opus フォールバック
    func testParseSevenDayOpusFallback() throws {
        let json = """
        {
            "five_hour": { "utilization": 10.0, "resets_at": "2026-07-22T09:00:00+00:00" },
            "seven_day": { "utilization": 20.0, "resets_at": "2026-07-25T00:59:59+00:00" },
            "seven_day_opus": { "utilization": 5.0, "resets_at": "2026-07-25T00:59:59+00:00" }
        }
        """.data(using: .utf8)!

        let (snapshot, fableLabel) = try UsageParser.parse(json)
        XCTAssertEqual(snapshot.weeklyFable?.utilization, 5.0)
        XCTAssertEqual(fableLabel, "Opus")
    }

    // five_hour がない（アクティブセッションなし）でも落ちない
    func testParseNullFiveHour() throws {
        let json = """
        { "five_hour": null, "seven_day": { "utilization": 2.0, "resets_at": null } }
        """.data(using: .utf8)!

        let (snapshot, _) = try UsageParser.parse(json)
        XCTAssertNil(snapshot.session)
        XCTAssertEqual(snapshot.weeklyAll?.utilization, 2.0)
        XCTAssertNil(snapshot.weeklyAll?.resetsAt)
    }

    // モデル名のない weekly_scoped（surface 枠）を Fable 枠へ入れない
    func testSurfaceScopedLimitIsNotTreatedAsModel() throws {
        let json = """
        {
            "limits": [
                { "kind": "weekly_scoped", "percent": 77, "scope": { "model": null, "surface": "design" } },
                { "kind": "weekly_scoped", "percent": 5, "scope": { "model": { "id": null, "display_name": "Fable" } } }
            ]
        }
        """.data(using: .utf8)!

        let (snapshot, fableLabel) = try UsageParser.parse(json)
        XCTAssertEqual(snapshot.weeklyFable?.utilization, 5)
        XCTAssertEqual(fableLabel, "Fable")
    }

    // モデル別の行が複数あれば、並び順によらず Fable を選ぶ
    func testFablePreferredAmongModelLimits() throws {
        let json = """
        {
            "limits": [
                { "kind": "weekly_scoped", "percent": 5, "scope": { "model": { "display_name": "Sonnet" } } },
                { "kind": "weekly_scoped", "percent": 90, "scope": { "model": { "display_name": "Fable" } } }
            ]
        }
        """.data(using: .utf8)!

        let (snapshot, fableLabel) = try UsageParser.parse(json)
        XCTAssertEqual(snapshot.weeklyFable?.utilization, 90)
        XCTAssertEqual(fableLabel, "Fable")
    }

    // Fable が無ければ先頭のモデルをそのラベルで出す
    func testOtherModelLimitKeepsItsLabel() throws {
        let json = """
        { "limits": [ { "kind": "weekly_scoped", "percent": 8, "scope": { "model": { "display_name": "Opus" } } } ] }
        """.data(using: .utf8)!

        let (snapshot, fableLabel) = try UsageParser.parse(json)
        XCTAssertEqual(snapshot.weeklyFable?.utilization, 8)
        XCTAssertEqual(fableLabel, "Opus")
    }

    func testISO8601FractionalAndPlain() {
        XCTAssertNotNil(UsageParser.date("2026-04-11T07:00:00.528743+00:00"))
        XCTAssertNotNil(UsageParser.date("2026-04-11T07:00:00Z"))
        XCTAssertNil(UsageParser.date(nil))
        XCTAssertNil(UsageParser.date("not-a-date"))
    }
}

final class PlanAndSessionTests: XCTestCase {
    func testPlanNames() {
        XCTAssertEqual(ClaudePlan.displayName(organizationType: "claude_max", rateLimitTier: "default_claude_max_5x"), "Max")
        XCTAssertEqual(ClaudePlan.displayName(organizationType: "claude_max", rateLimitTier: "default_claude_max_20x"), "Ultra")
        XCTAssertEqual(ClaudePlan.displayName(organizationType: "claude_ultra", rateLimitTier: nil), "Ultra")
        XCTAssertEqual(ClaudePlan.displayName(organizationType: "claude_pro", rateLimitTier: nil), "Pro")
        XCTAssertEqual(ClaudePlan.displayName(organizationType: "claude_team", rateLimitTier: nil), "Team")
        XCTAssertEqual(ClaudePlan.displayName(organizationType: "claude_new_plan", rateLimitTier: nil), "New Plan")
        XCTAssertNil(ClaudePlan.displayName(organizationType: nil, rateLimitTier: nil))
    }

    // 未使用のセッションは枠あり（0%・リセット時刻なし）
    func testIdleSessionIsKept() throws {
        let json = """
        {
            "five_hour": { "utilization": 0, "resets_at": null },
            "limits": [ { "kind": "session", "percent": 0, "resets_at": null, "scope": null } ]
        }
        """.data(using: .utf8)!
        XCTAssertEqual(try UsageParser.parse(json).snapshot.session?.utilization, 0)
    }

    // 5時間制限の無いプラン: five_hour が null
    func testNoSessionLimitWithNullFiveHour() throws {
        let json = """
        { "five_hour": null, "seven_day": { "utilization": 6, "resets_at": null },
          "limits": [ { "kind": "weekly_all", "percent": 6 } ] }
        """.data(using: .utf8)!
        let snapshot = try UsageParser.parse(json).snapshot
        XCTAssertNil(snapshot.session)
        XCTAssertEqual(snapshot.weeklyAll?.utilization, 6)
    }

    // 5時間制限の無いプラン: five_hour は空で、limits に session 行が無い
    func testNoSessionLimitWithoutSessionRow() throws {
        let json = """
        { "five_hour": { "utilization": 0, "resets_at": null },
          "limits": [ { "kind": "weekly_all", "percent": 6 } ] }
        """.data(using: .utf8)!
        XCTAssertNil(try UsageParser.parse(json).snapshot.session)
    }

    // limits の session 行だけでも読める
    func testSessionFromLimitsRow() throws {
        let json = """
        { "five_hour": null, "limits": [ { "kind": "session", "percent": 12, "resets_at": "2026-11-01T11:10:00+00:00" } ] }
        """.data(using: .utf8)!
        XCTAssertEqual(try UsageParser.parse(json).snapshot.session?.utilization, 12)
    }

    // 中身のない 200 応答で正常値を上書きしない
    func testEmptyResponseThrows() {
        XCTAssertThrowsError(try UsageParser.parse("{}".data(using: .utf8)!))
    }

    // 古いキャッシュ: リセット時刻を過ぎた枠は 0% に、まだ先の枠はそのまま
    func testClearingExpiredWindows() {
        let now = Date(timeIntervalSince1970: 1000)
        var snapshot = UsageSnapshot()
        snapshot.session = UsageWindow(utilization: 100, resetsAt: Date(timeIntervalSince1970: 500))
        snapshot.weeklyAll = UsageWindow(utilization: 40, resetsAt: Date(timeIntervalSince1970: 2000))
        let cleared = snapshot.clearingExpiredWindows(now: now)
        XCTAssertEqual(cleared.session?.utilization, 0)
        XCTAssertNil(cleared.session?.resetsAt)
        XCTAssertEqual(cleared.weeklyAll?.utilization, 40)
    }

    // 公式の「週間の利用上限の最大 50%」
    func testModelAllowanceFromShares() throws {
        let json = """
        {
            "limits": [
                { "kind": "session", "percent": 1 },
                { "kind": "weekly_all", "percent": 6 },
                { "kind": "weekly_scoped", "percent": 5, "scope": { "model": { "display_name": "Fable" } } }
            ],
            "weekly_scoped_shares": [ { "limit_index": 2, "used_percent_of_weekly": 3, "allowance_percent_of_weekly": 50 } ]
        }
        """.data(using: .utf8)!
        XCTAssertEqual(try UsageParser.parse(json).snapshot.weeklyFableAllowancePercent, 50)
    }

    // API の 00:59:59.9 を公式画面と同じ 01:00 に揃える
    func testResetTimeRoundsToNearestMinute() {
        let date = Date(timeIntervalSince1970: 3599.9)
        XCTAssertEqual(UsageGaugeView.roundedToMinute(date).timeIntervalSince1970, 3600)
    }

    @MainActor
    func testEffectiveMetricFallsBackToWeekly() {
        let state = AppState()
        XCTAssertEqual(state.effectiveMetric(.session), .session) // 未取得の間は切り替えない
        XCTAssertFalse(state.isMetricAbsent(.session))
        var snapshot = UsageSnapshot()
        snapshot.weeklyAll = UsageWindow(utilization: 6, resetsAt: nil)
        state.usage = snapshot
        XCTAssertEqual(state.effectiveMetric(.session), .weekly)
        XCTAssertTrue(state.isMetricAbsent(.session))
        XCTAssertEqual(state.menuBarPercentText, "6%")
    }
}

/// コードレビューで見つかった不具合の再発防止
final class ReviewRegressionTests: XCTestCase {
    // 期間枠が無く追加利用だけのアカウントはエラーにしない
    func testExtraUsageOnlyIsValid() throws {
        let json = #"{"five_hour":null,"seven_day":null,"extra_usage":{"is_enabled":true,"utilization":12.0}}"#
        let snapshot = try UsageParser.parse(Data(json.utf8)).snapshot
        XCTAssertNil(snapshot.session)
        XCTAssertEqual(snapshot.extra?.isEnabled, true)
    }

    // 枠のある表示を、枠の全く無い応答で置き換えない。最初から枠が無いプランは表示できる
    func testWindowlessResponseDoesNotReplaceRealUsage() {
        var real = UsageSnapshot()
        real.session = UsageWindow(utilization: 40, resetsAt: nil)
        let empty = UsageSnapshot()
        XCTAssertFalse(empty.canReplace(real))
        XCTAssertTrue(empty.canReplace(nil))
        XCTAssertTrue(empty.canReplace(UsageSnapshot()))
        XCTAssertTrue(real.canReplace(empty))
        XCTAssertTrue(real.canReplace(real))
    }

    // 枠の割合の異常値も表示でクラッシュしない
    func testHugeAllowanceIsClamped() throws {
        let json = #"{"limits":[{"kind":"weekly_scoped","percent":5,"scope":{"model":{"display_name":"Fable"}}}],"weekly_scoped_shares":[{"limit_index":0,"allowance_percent_of_weekly":1e300}]}"#
        XCTAssertEqual(try UsageParser.parse(Data(json.utf8)).snapshot.weeklyFableAllowancePercent, 1000)
    }

    // 枠の無い応答は、間を空けず1時間続くまで受け入れない
    func testWindowlessGuardNeedsSustainedResponses() {
        var guardState = WindowlessResponseGuard()
        let start = Date()
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
        XCTAssertFalse(guardState.shouldAccept(now: at(0)))
        XCTAssertFalse(guardState.shouldAccept(now: at(1)))
        XCTAssertFalse(guardState.shouldAccept(now: at(2))) // 回数だけでは受け入れない
        for minute in stride(from: 10.0, to: 60, by: 10) {
            XCTAssertFalse(guardState.shouldAccept(now: at(minute)))
        }
        XCTAssertTrue(guardState.shouldAccept(now: at(60)))
    }

    // 取得失敗などで間が空いたら数え直す。正常な応答でも数え直す
    func testWindowlessGuardRestartsAfterGapOrGoodResponse() {
        var guardState = WindowlessResponseGuard()
        let start = Date()
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
        XCTAssertFalse(guardState.shouldAccept(now: at(0)))
        XCTAssertFalse(guardState.shouldAccept(now: at(300))) // 5時間空いた
        XCTAssertFalse(guardState.shouldAccept(now: at(310)))
        guardState.reset()
        XCTAssertFalse(guardState.shouldAccept(now: at(370)))
    }

    // 今日の更新は時刻だけ、今日以外は日付も出す
    func testUpdatedTextShowsDateWhenNotToday() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(UsageGaugeView.updatedClockText(now, now: now), UsageGaugeView.clockText(now))
        let old = UsageGaugeView.updatedClockText(yesterday, now: now)
        XCTAssertNotEqual(old, UsageGaugeView.clockText(yesterday))
        XCTAssertTrue(old.contains(String(Calendar.current.component(.day, from: yesterday))))
    }

    // トークンを送るセッションはディスクへ何も残さない
    func testTokenSessionHasNoDiskCache() {
        let config = UsageService.makeTokenSession().configuration
        XCTAssertNil(config.urlCache)
        XCTAssertNil(config.httpCookieStorage)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    // 異常に大きい値でも、表示の Int 変換でクラッシュしない範囲に収める
    func testHugePercentIsClamped() throws {
        let json = #"{"five_hour":{"utilization":1e300},"seven_day":{"utilization":-5}}"#
        let snapshot = try UsageParser.parse(Data(json.utf8)).snapshot
        XCTAssertEqual(snapshot.session?.utilization, 1000)
        XCTAssertEqual(snapshot.weeklyAll?.utilization, 0)
        XCTAssertEqual(UsageParser.sanePercent(.infinity), 0)
    }

    // ログインコマンドの引用: 引用符を含むパスでスクリプトが壊れない
    func testLoginCommandQuoting() {
        XCTAssertEqual(LoginHelper.shellQuoted("/a/b's/claude"), #"'/a/b'\''s/claude'"#)
        XCTAssertEqual(LoginHelper.appleScriptEscaped(#"say "hi" \o"#), #"say \"hi\" \\o"#)
    }

    // 期間枠の無いプランの応答（追加利用は無効）もエラーにしない
    func testAccountWithoutWindowsIsValid() throws {
        let json = #"{"five_hour":null,"seven_day":null,"extra_usage":{"is_enabled":false}}"#
        let snapshot = try UsageParser.parse(Data(json.utf8)).snapshot
        XCTAssertNil(snapshot.session)
        XCTAssertEqual(snapshot.extra?.isEnabled, false)
    }

    // 全項目が null で extra_usage も無い応答は、正常値を上書きしないようエラー
    func testAllNullWithoutExtraUsageThrows() {
        let json = #"{"five_hour":null,"seven_day":null}"#
        XCTAssertThrowsError(try UsageParser.parse(Data(json.utf8)))
    }

    func testHasExpiredWindows() {
        let now = Date()
        var snapshot = UsageSnapshot()
        XCTAssertFalse(snapshot.hasExpiredWindows(now: now))
        snapshot.session = UsageWindow(utilization: 80, resetsAt: nil)
        XCTAssertFalse(snapshot.hasExpiredWindows(now: now))
        snapshot.weeklyAll = UsageWindow(utilization: 80, resetsAt: now.addingTimeInterval(60))
        XCTAssertFalse(snapshot.hasExpiredWindows(now: now))
        snapshot.weeklyFable = UsageWindow(utilization: 80, resetsAt: now.addingTimeInterval(-60))
        XCTAssertTrue(snapshot.hasExpiredWindows(now: now))
        XCTAssertFalse(snapshot.clearingExpiredWindows(now: now).hasExpiredWindows(now: now))
    }

    // claude を起動してもキャッシュが無いとき、起動の間隔制限が効くよう ranCLI を返す
    func testRanCLIIsReportedWithoutCache() async {
        var launches = 0
        let result = await ClaudeUsageBridge.fetchUtilizationJSON(
            maxAge: 60, readCache: { nil }, runCLI: { launches += 1; return true }
        )
        XCTAssertEqual(launches, 1)
        XCTAssertTrue(result.ranCLI)
        XCTAssertNil(result.usage)
    }

    func testCLINotLaunchedWhenThrottledOrFresh() async {
        var launches = 0
        let throttled = await ClaudeUsageBridge.fetchUtilizationJSON(
            maxAge: 60, allowCLIRefresh: false, readCache: { nil }, runCLI: { launches += 1; return true }
        )
        XCTAssertFalse(throttled.ranCLI)
        let fresh = await ClaudeUsageBridge.fetchUtilizationJSON(
            maxAge: 60, readCache: { (Data("{}".utf8), 1) }, runCLI: { launches += 1; return true }
        )
        XCTAssertFalse(fresh.ranCLI)
        XCTAssertEqual(launches, 0)
    }

    // claude が見つからないときは起動扱いにしない
    func testMissingCLIIsNotCountedAsLaunch() async {
        let result = await ClaudeUsageBridge.fetchUtilizationJSON(maxAge: 60, readCache: { nil }, runCLI: { false })
        XCTAssertFalse(result.ranCLI)
    }

    func testBackoffWaitsAfterRepeatedFailures() {
        var backoff = BackdropFailureBackoff()
        XCTAssertNil(backoff.recordFailure())
        XCTAssertNil(backoff.recordFailure())
        XCTAssertEqual(backoff.recordFailure(), 60)
        XCTAssertEqual(backoff.recordFailure(), 120)
        XCTAssertEqual(backoff.recordFailure(), 240)
        XCTAssertEqual(backoff.recordFailure(), 300)
        backoff.recordSuccess()
        XCTAssertNil(backoff.recordFailure())
    }
}

final class BackdropToneTests: XCTestCase {
    func testFirstSampleDecidesImmediately() {
        var tone = BackdropTone()
        XCTAssertEqual(tone.update(luminance: 0.1), .dark)
    }

    func testSwitchNeedsTwoSamples() {
        var tone = BackdropTone()
        tone.update(luminance: 0.1)
        XCTAssertEqual(tone.update(luminance: 0.9), .dark)
        XCTAssertEqual(tone.update(luminance: 0.9), .light)
    }

    // 中間の明るさでは今の外観を保ち、切り替え待ちも取り消す
    func testMiddleLuminanceKeepsTone() {
        var tone = BackdropTone()
        tone.update(luminance: 0.1)
        tone.update(luminance: 0.9)
        XCTAssertEqual(tone.update(luminance: 0.5), .dark)
        XCTAssertEqual(tone.update(luminance: 0.9), .dark)
    }
}

final class UsageResetDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // 未使用のセッション: リセット時刻を過ぎて null になったらリセット済み
    func testPastResetWithNullCurrentIsReset() {
        XCTAssertTrue(UsageResetDetector.hasReset(previous: now.addingTimeInterval(-120), current: nil, now: now))
    }

    // まだ先のリセット時刻で null が来ても一時的な欠損とみなす
    func testFutureResetWithNullCurrentIsNotReset() {
        XCTAssertFalse(UsageResetDetector.hasReset(previous: now.addingTimeInterval(3600), current: nil, now: now))
    }

    func testNewPeriodIsReset() {
        let previous = now.addingTimeInterval(-120)
        XCTAssertTrue(UsageResetDetector.hasReset(previous: previous, current: now.addingTimeInterval(18000), now: now))
    }

    // 同じ期間の秒単位の揺れはリセットではない
    func testSecondsJitterIsNotReset() {
        let previous = now.addingTimeInterval(-120)
        XCTAssertFalse(UsageResetDetector.hasReset(previous: previous, current: previous.addingTimeInterval(1), now: now))
    }

    // 時刻が大きく動いても、控えた時刻がまだ先ならリセットとみなさない
    func testFutureResetMovedLaterIsNotReset() {
        let previous = now.addingTimeInterval(3600)
        XCTAssertFalse(UsageResetDetector.hasReset(previous: previous, current: previous.addingTimeInterval(7200), now: now))
    }
}

final class CredentialsStoreTests: XCTestCase {

    func testParseValidCredentials() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-xxxx",
            "refreshToken": "sk-ant-ort01-xxxx",
            "expiresAt": 9999999999999,
            "scopes": ["user:inference", "user:profile"],
            "subscriptionType": "max"
          }
        }
        """.data(using: .utf8)!
        let creds = try CredentialsStore.parse(json)
        XCTAssertEqual(creds.accessToken, "sk-ant-oat01-xxxx")
    }

    // Claude Code 2.1.x の一部環境: mcpOAuthのみ → 専用エラー
    func testParseMcpOnlyPayload() {
        let json = """
        { "mcpOAuth": { "someServer": { "accessTokens": {} } } }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try CredentialsStore.parse(json)) { error in
            XCTAssertEqual(error as? CredentialsError, .mcpOnly)
        }
    }

    func testParseMissingProfileScope() {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-xxxx",
            "expiresAt": 9999999999999,
            "scopes": ["user:inference"]
          }
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try CredentialsStore.parse(json)) { error in
            XCTAssertEqual(error as? CredentialsError, .missingProfileScope)
        }
    }

    // 失効判定はキャッシュ層(load)が担うため、parseは期限切れでも失効日時付きで返す
    func testParseExpiredTokenReturnsPastExpiry() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-xxxx",
            "expiresAt": 1000,
            "scopes": ["user:inference", "user:profile"]
          }
        }
        """.data(using: .utf8)!
        let creds = try CredentialsStore.parse(json)
        XCTAssertEqual(creds.accessToken, "sk-ant-oat01-xxxx")
        let expiresAt = try XCTUnwrap(creds.expiresAt)
        XCTAssertLessThan(expiresAt, Date())
    }
}
