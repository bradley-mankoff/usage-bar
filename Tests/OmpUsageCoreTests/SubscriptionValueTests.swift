import XCTest
@testable import OmpUsageCore

final class SubscriptionValueTests: XCTestCase {
    func testKnownProviders() {
        XCTAssertEqual(SubscriptionValue.valueUsd(provider: "opencode-go", planType: "OpenCode Go"), 60)
        XCTAssertEqual(SubscriptionValue.valueUsd(provider: "xai-oauth", planType: nil), 200)
        XCTAssertEqual(SubscriptionValue.valueUsd(provider: "anthropic", planType: nil), 150)
    }

    func testAnthropicMaxTiers() {
        XCTAssertEqual(SubscriptionValue.valueUsd(provider: "anthropic", planType: "Max 5x"), 750)
        XCTAssertEqual(SubscriptionValue.valueUsd(provider: "anthropic", planType: "Max 20x"), 1500)
    }

    func testUnknownProviderHasNoValue() {
        XCTAssertNil(SubscriptionValue.valueUsd(provider: "openrouter", planType: nil))
        XCTAssertNil(SubscriptionValue.valueUsd(provider: "nope", planType: nil))
    }

    func testWeightedFraction() {
        // Live-shape example, weekly windows only: Go 18% ($60), xAI 100%
        // ($200), Anthropic 0% ($150) -> (10.8 + 200 + 0) / 410 ~= 51.4%.
        let frac = SubscriptionValue.weightedFraction([(0.18, 60), (1.0, 200), (0.0, 150)])
        XCTAssertEqual(frac ?? -1, 210.8 / 410, accuracy: 1e-9)
    }

    func testWeightedFractionEmptyIsNil() {
        XCTAssertNil(SubscriptionValue.weightedFraction([]))
        XCTAssertNil(SubscriptionValue.weightedFraction([(0.5, 0)]))
    }

    func testIsWeekly() {
        XCTAssertTrue(SubscriptionValue.isWeekly(windowId: "7d", limitId: "weekly"))
        XCTAssertTrue(SubscriptionValue.isWeekly(windowId: "1w", limitId: "xai-oauth:credits:1w"))
        XCTAssertTrue(SubscriptionValue.isWeekly(windowId: "5h", limitId: "anthropic:7d"))
        XCTAssertFalse(SubscriptionValue.isWeekly(windowId: "5h", limitId: "rolling-5h"))
        XCTAssertFalse(SubscriptionValue.isWeekly(windowId: "monthly", limitId: "monthly"))
        XCTAssertFalse(SubscriptionValue.isWeekly(windowId: nil, limitId: "monthly"))
    }

    func testWeeklyFractionPicksMaxWeekly() {
        let frac = SubscriptionValue.weeklyFraction(limits: [
            (windowId: "5h", limitId: "rolling-5h", usedFraction: 0.0),
            (windowId: "7d", limitId: "weekly", usedFraction: 0.18),
            (windowId: "monthly", limitId: "monthly", usedFraction: 0.74),
        ])
        XCTAssertEqual(frac ?? -1, 0.18, accuracy: 1e-9)
    }

    func testWeeklyFractionNilWithoutWeekly() {
        XCTAssertNil(SubscriptionValue.weeklyFraction(limits: [
            (windowId: "monthly", limitId: "monthly", usedFraction: 0.74),
        ]))
    }

    func testXaiLookup() {
        XCTAssertEqual(GoCatalog.xaiLookup("grok-4.6").inputPerM, 2)
        XCTAssertEqual(GoCatalog.xaiLookup("grok-4.5").outputPerM, 9)
        // Unknown model falls back to Grok 4.6 rates.
        XCTAssertEqual(GoCatalog.xaiLookup("grok-9").inputPerM, 2)
        XCTAssertEqual(GoCatalog.xaiLookup("grok-9").outputPerM, 6)
    }

    func testXaiListPrice() {
        let event = ModelValue.TokenEvent(
            timestampMs: 1_000, model: "grok-4.6", costUsd: 0.01,
            inputTokens: 1_000_000, outputTokens: 1_000_000,
            cacheReadTokens: 1_000_000, cacheWriteTokens: 0
        )
        XCTAssertEqual(ModelValue.xaiListPrice(event), 2 + 6 + 0.5, accuracy: 1e-9)
    }

    func testEstimateXaiWindow() {
        let obs = [
            NerfTrack.Observation(timestampMs: 1_000, usedPercent: 10, resetAtMs: 9_000),
            NerfTrack.Observation(timestampMs: 2_000, usedPercent: 20, resetAtMs: 9_000),
        ]
        let events = [ModelValue.TokenEvent(
            timestampMs: 1_500, model: "grok-4.6", costUsd: 0.001,
            inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0
        )]
        let quotes = ModelValue.estimate(
            provider: "xai-oauth", windowId: "xai-oauth:credits:1w",
            observations: obs, events: events
        )
        XCTAssertEqual(quotes.count, 1)
        XCTAssertEqual(quotes[0].deliveredUsd, 2.0, accuracy: 1e-9)
        XCTAssertEqual(quotes[0].displayName, "Grok 4.6")
    }
}
