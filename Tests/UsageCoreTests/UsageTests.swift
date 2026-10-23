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
        XCTAssertFalse(windows[0].isWeekly)
        XCTAssertTrue(windows[1].isWeekly)
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
        XCTAssertEqual(windows.filter(\.isWeekly).map(\.id), ["weekly"])
        XCTAssertEqual(windows[2].usedFraction, 0.72, accuracy: 1e-9)
        XCTAssertNotNil(windows[1].resetsAt)
    }

    func testOpenRouterCredits() throws {
        let credits = try OpenRouter.parse(Data(#"{"data":{"total_credits":20,"total_usage":3.377419953}}"#.utf8))
        XCTAssertEqual(credits.remaining, 16.622580047, accuracy: 1e-9)
        XCTAssertEqual(credits.usedFraction!, 0.16887, accuracy: 1e-4)
        XCTAssertNil(OpenRouter.Credits(totalCredits: 0, totalUsage: 0).usedFraction)
    }

    func testWeightedWeeklyFraction() {
        let claude = SubscriptionUsage(name: "Claude", plan: "Pro", monthlyValueUsd: 150, windows: [
            UsageWindow(id: "five_hour", label: "5 Hour", usedFraction: 0.9, resetsAt: nil, isWeekly: false),
            UsageWindow(id: "seven_day", label: "Weekly", usedFraction: 0.28, resetsAt: nil, isWeekly: true),
        ])
        let go = SubscriptionUsage(name: "OpenCode Go", plan: nil, monthlyValueUsd: 60, windows: [
            UsageWindow(id: "weekly", label: "Weekly", usedFraction: 0.04, resetsAt: nil, isWeekly: true),
        ])
        // (0.28 * 150 + 0.04 * 60) / 210; the 5-hour 90% must not count.
        XCTAssertEqual(SubscriptionValue.weightedWeeklyFraction([claude, go])!, 44.4 / 210, accuracy: 1e-9)
        XCTAssertNil(SubscriptionValue.weightedWeeklyFraction([]))
    }

    func testClaudePlanValue() {
        XCTAssertEqual(SubscriptionValue.claudeUsd(plan: "pro", tier: "default_claude_ai"), 150)
        XCTAssertEqual(SubscriptionValue.claudeUsd(plan: "max", tier: "default_claude_max_5x"), 750)
        XCTAssertEqual(SubscriptionValue.claudeUsd(plan: "max", tier: "default_claude_max_20x"), 1500)
    }
}
