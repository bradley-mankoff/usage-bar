import XCTest
@testable import UsageCore

/// Fixtures are trimmed copies of real responses captured 2026-10-23.
final class UsageTests: XCTestCase {
    func testClaudeParsesNamedWindowsAndSkipsNulls() throws {
        let json = """
        {"five_hour": {"utilization": 61.0, "resets_at": "2026-10-23T19:39:59.627930+00:00"},
         "seven_day": {"utilization": 28.0, "resets_at": "2026-10-27T05:59:59.627952+00:00"},
         "seven_day_opus": null,
         "iguana_necktie": {"utilization": 0.0, "limit_dollars": 100}}
        """
        let windows = try Claude.parse(Data(json.utf8))
        XCTAssertEqual(windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(windows[0].usedFraction, 0.61, accuracy: 1e-9)
        XCTAssertEqual(windows[1].resetsAt, ISO8601DateFormatter().date(from: "2026-10-27T05:59:59Z"))
    }

    func testOpenCodeGoParsesThreeWindows() throws {
        let json = """
        {"usage": {"rolling": {"status": "ok", "percent": 0, "resetsAt": "2026-10-23T19:55:59.000Z"},
                   "weekly": {"status": "ok", "percent": 4, "resetsAt": "2026-10-26T00:00:00.000Z"},
                   "monthly": {"status": "ok", "percent": 72, "resetsAt": "2026-11-02T19:15:41.000Z"}}}
        """
        let windows = try OpenCodeGo.parse(Data(json.utf8))
        XCTAssertEqual(windows.map(\.id), ["rolling", "weekly", "monthly"])
        XCTAssertEqual(windows[2].usedFraction, 0.72, accuracy: 1e-9)
        XCTAssertNotNil(windows[1].resetsAt)
    }

    func testOpenRouterCredits() throws {
        let credits = try OpenRouter.parse(Data(#"{"data":{"total_credits":20,"total_usage":3.377419953}}"#.utf8))
        XCTAssertEqual(credits.remaining, 16.622580047, accuracy: 1e-9)
        XCTAssertEqual(credits.usedFraction!, 0.16887, accuracy: 1e-4)
        XCTAssertNil(OpenRouter.Credits(totalCredits: 0, totalUsage: 0).usedFraction)
    }

    func testMenuBarTextShowsClaudeFiveHourThenWeeklyPercent() {
        let text = MenuBarLabel.text(
            claudeWindows: claudeWindows(fiveHour: 0.12, weekly: 0.40),
            firstFetchDone: true
        )
        XCTAssertEqual(text, "12% \u{00B7} 40%")
    }

    func testMenuBarTextKeepsOneDecimalBelowTenPercent() {
        let text = MenuBarLabel.text(
            claudeWindows: claudeWindows(fiveHour: 0.045, weekly: 0.40),
            firstFetchDone: true
        )
        XCTAssertEqual(text, "4.5% \u{00B7} 40%")
    }

    func testMenuBarTextShowsTheOneClaudeWindowPresent() {
        let fiveHourOnly = MenuBarLabel.text(
            claudeWindows: claudeWindows(fiveHour: 0.12),
            firstFetchDone: true
        )
        let weeklyOnly = MenuBarLabel.text(
            claudeWindows: claudeWindows(weekly: 0.40),
            firstFetchDone: true
        )
        XCTAssertEqual(fiveHourOnly, "12%")
        XCTAssertEqual(weeklyOnly, "40%")
    }

    func testMenuBarTextWithoutClaudeWindows() {
        XCTAssertEqual(MenuBarLabel.text(claudeWindows: nil, firstFetchDone: false), "\u{2026}")
        XCTAssertEqual(MenuBarLabel.text(claudeWindows: nil, firstFetchDone: true), "?")
        XCTAssertEqual(MenuBarLabel.text(claudeWindows: [], firstFetchDone: true), "?")
    }

    func testAFailedClaudePollKeepsTheLastGoodTwoPercentsInTheBar() {
        XCTAssertEqual(
            barTextAfterAPoll(.failure(UsageError.http(500, "Claude usage"))),
            "12% \u{00B7} 40%"
        )
    }

    func testAMissingClaudeCredentialKeepsTheLastGoodTwoPercentsInTheBar() {
        XCTAssertEqual(barTextAfterAPoll(nil), "12% \u{00B7} 40%")
    }

    func testBarShowsEllipsisBeforeTheFirstPollAndQuestionMarkWhenNoPollSucceeded() {
        let beforeFirstPoll = Claude.keepingLastGood(nil, after: nil)
        XCTAssertEqual(barText(beforeFirstPoll, firstFetchDone: false), "\u{2026}")

        let firstPollFailed = Claude.keepingLastGood(
            nil, after: .failure(UsageError.http(500, "Claude usage"))
        )
        XCTAssertEqual(barText(firstPollFailed), "?")
    }

    /// The bar text `UsageStore` would show for a stored Claude result.
    private func barText(
        _ claude: Result<SubscriptionUsage, Error>?, firstFetchDone: Bool = true
    ) -> String {
        MenuBarLabel.text(claudeWindows: try? claude?.get().windows, firstFetchDone: firstFetchDone)
    }

    /// The bar text after one good poll of 12% and 40%, then `poll`.
    private func barTextAfterAPoll(_ poll: Result<SubscriptionUsage, Error>?) -> String {
        let good = Result<SubscriptionUsage, Error>.success(
            claudeUsage(fiveHour: 0.12, weekly: 0.40)
        )
        return barText(Claude.keepingLastGood(Claude.keepingLastGood(nil, after: good), after: poll))
    }

    private func claudeUsage(fiveHour: Double? = nil, weekly: Double? = nil) -> SubscriptionUsage {
        SubscriptionUsage(
            name: "Claude", plan: "Pro", windows: claudeWindows(fiveHour: fiveHour, weekly: weekly)
        )
    }

    private func claudeWindows(fiveHour: Double? = nil, weekly: Double? = nil) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        if let fiveHour {
            windows.append(UsageWindow(
                id: "five_hour", label: "5 Hour", usedFraction: fiveHour, resetsAt: nil
            ))
        }
        if let weekly {
            windows.append(UsageWindow(
                id: "seven_day", label: "Weekly", usedFraction: weekly, resetsAt: nil
            ))
        }
        return windows
    }

    func testCodexParsesWhamUsage() throws {
        let json = """
        {"email": "a-seat@example.com", "plan_type": "team",
         "rate_limit": {"allowed": true, "limit_reached": false,
          "primary_window": {"used_percent": 42, "limit_window_seconds": 18000, "reset_at": 1792798913},
          "secondary_window": {"used_percent": 7, "limit_window_seconds": 604800, "reset_at": 1793385713}}}
        """
        let (windows, note) = try Codex.parse(Data(json.utf8))
        XCTAssertEqual(windows.map(\.id), ["openai-codex:primary_window", "openai-codex:secondary_window"])
        XCTAssertEqual(windows[0].usedFraction, 0.42, accuracy: 1e-9)
        XCTAssertEqual(windows[1].usedFraction, 0.07, accuracy: 1e-9)
        XCTAssertEqual(windows[0].resetsAt, Date(timeIntervalSince1970: 1792798913))
        XCTAssertNil(note)
    }

    func testCodexSurfacesWorkspaceUpsell() throws {
        let json = """
        {"rate_limit": {"allowed": false, "limit_reached": true,
          "primary_window": {"used_percent": 100, "reset_at": 1792798657},
          "secondary_window": {"used_percent": 16, "reset_at": 1793385457}},
         "rate_limit_upsell": {"description": "Your workspace is out of credits. Add credits to continue using Codex."}}
        """
        let (windows, note) = try Codex.parse(Data(json.utf8))
        XCTAssertEqual(windows[0].usedFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(note, "Your workspace is out of credits. Add credits to continue using Codex.")
    }

    func testCodexSeatsComeFromPiCodexLogins() {
        // Payload {"https://api.openai.com/profile": {"email": "a-seat@example.com"}}, unsigned.
        let jwt = "e30.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL3Byb2ZpbGUiOnsiZW1haWwiOiJhLXNlYXRAZXhhbXBsZS5jb20ifX0.sig"
        let auth: [String: [String: Any]] = [
            "codex-seat-a": ["type": "oauth", "access": jwt, "accountId": "acct-1", "expires": 1_900_000_000_000.0],
            "codex-seat-b": ["type": "oauth", "access": "opaque", "expires": 1_000.0],
            "anthropic": ["type": "oauth", "access": "sk-ant", "expires": 1_900_000_000_000.0],
            "opencode-go": ["type": "api_key", "key": "k"],
        ]
        let seats = Codex.seats(fromPiAuth: auth)
        XCTAssertEqual(seats.map(\.email), ["a-seat@example.com", "codex-seat-b"])
        XCTAssertEqual(seats[0].accountId, "acct-1")
        XCTAssertFalse(seats[0].isExpired)
        XCTAssertTrue(seats[1].isExpired)
    }

    func testCodexResetCreditsKeepAvailableSoonestFirst() {
        let json = """
        {"credits": [
          {"status": "available", "title": "Full reset (Weekly + 5 hr)", "expires_at": "2026-11-30T20:33:00.984143Z"},
          {"status": "redeemed", "title": "Full reset (Weekly + 5 hr)", "expires_at": "2026-11-01T00:00:00Z"},
          {"status": "available", "title": "Full reset (Weekly + 5 hr)", "expires_at": "2026-11-06T23:53:33.856823Z"}],
         "available_count": 2}
        """
        let credits = Codex.parseResetCredits(Data(json.utf8))
        XCTAssertEqual(credits.map(\.expiresAt), [
            ISO8601DateFormatter().date(from: "2026-11-06T23:53:33Z"),
            ISO8601DateFormatter().date(from: "2026-11-30T20:33:00Z"),
        ])
        XCTAssertEqual(credits[0].title, "Full reset (Weekly + 5 hr)")
        XCTAssertEqual(Codex.parseResetCredits(Data(#"{"detail": "nope"}"#.utf8)), [])
    }

    func testCodexRejectsForeignShape() {
        XCTAssertThrowsError(try Codex.parse(Data(#"{"usage": {}}"#.utf8)))
    }
}
