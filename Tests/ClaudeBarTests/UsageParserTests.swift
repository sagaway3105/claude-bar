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

    func testISO8601FractionalAndPlain() {
        XCTAssertNotNil(UsageParser.date("2026-04-11T07:00:00.528743+00:00"))
        XCTAssertNotNil(UsageParser.date("2026-04-11T07:00:00Z"))
        XCTAssertNil(UsageParser.date(nil))
        XCTAssertNil(UsageParser.date("not-a-date"))
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

    func testParseExpiredToken() {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-xxxx",
            "expiresAt": 1000,
            "scopes": ["user:inference", "user:profile"]
          }
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try CredentialsStore.parse(json)) { error in
            XCTAssertEqual(error as? CredentialsError, .expired)
        }
    }
}
