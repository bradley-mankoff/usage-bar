import XCTest
@testable import OmpUsageCore

final class NerfTrackTests: XCTestCase {
    func testPositiveTokenCostDeltaProjectsAWeek() {
        guard case let .valid(costDelta, _, estimate) = NerfTrack.measureInterval(
            previousCostUsd: 1,
            currentCostUsd: 1.42,
            previousUsedPercent: 42,
            currentUsedPercent: 43
        ) else {
            return XCTFail("expected valid")
        }
        XCTAssertEqual(costDelta, 0.42, accuracy: 1e-10)
        XCTAssertEqual(estimate, 42, accuracy: 1e-10)
    }

    func testDecimalPercentageChangesAreSupported() {
        guard case let .valid(_, _, estimate) = NerfTrack.measureInterval(
            previousCostUsd: 1,
            currentCostUsd: 1.21,
            previousUsedPercent: 12.25,
            currentUsedPercent: 12.75
        ) else {
            return XCTFail("expected valid")
        }
        XCTAssertEqual(estimate, 42, accuracy: 1e-10)
    }

    func testMissingPositivePairIsPending() {
        XCTAssertEqual(
            NerfTrack.measureInterval(
                previousCostUsd: 1,
                currentCostUsd: 1,
                previousUsedPercent: 1,
                currentUsedPercent: 2
            ),
            .pending
        )
    }

    func testUsageDecreaseIsRejected() {
        XCTAssertEqual(
            NerfTrack.measureInterval(
                previousCostUsd: 1,
                currentCostUsd: 2,
                previousUsedPercent: 42,
                currentUsedPercent: 41
            ),
            .rejected
        )
    }

    func testMedianResistsAnOutlier() {
        XCTAssertEqual(NerfTrack.medianRecent([42, 41, 43, 4200, 40]), 42)
    }

    func testHeadlineUsesCumulativeMedianAndLeavesUnpairedWindowPending() {
        let observations = [
            NerfTrack.Observation(timestampMs: 1_000, usedPercent: 0, resetAtMs: 100_000),
            NerfTrack.Observation(timestampMs: 2_000, usedPercent: 10, resetAtMs: 100_000),
            NerfTrack.Observation(timestampMs: 3_000, usedPercent: 20, resetAtMs: 100_000),
            // new weekly window: usage drop + reset moved
            NerfTrack.Observation(timestampMs: 4_000, usedPercent: 0, resetAtMs: 200_000),
            NerfTrack.Observation(timestampMs: 5_000, usedPercent: 50, resetAtMs: 200_000),
        ]
        let costs = [
            NerfTrack.CostEvent(timestampMs: 1_500, costUsd: 4.2),
            NerfTrack.CostEvent(timestampMs: 2_500, costUsd: 4.2),
        ]
        let quote = NerfTrack.estimate(observations: observations, costs: costs)
        XCTAssertEqual(quote.status, .pending)
        XCTAssertEqual(quote.lastCalibratedUsd ?? -1, 42, accuracy: 1e-9)
        XCTAssertNil(quote.estimatedWeeklyValueUsd)
        XCTAssertEqual(quote.weeklyUsedPercent ?? -1, 50, accuracy: 1e-9)
        XCTAssertEqual(quote.validObservationCount, 0)
    }

    func testCurrentWindowEstimateWhenPaired() {
        let observations = [
            NerfTrack.Observation(timestampMs: 1_000, usedPercent: 10, resetAtMs: 100_000),
            NerfTrack.Observation(timestampMs: 2_000, usedPercent: 20, resetAtMs: 100_000),
        ]
        let costs = [
            NerfTrack.CostEvent(timestampMs: 1_500, costUsd: 5),
        ]
        let quote = NerfTrack.estimate(observations: observations, costs: costs)
        XCTAssertEqual(quote.status, .valid)
        XCTAssertEqual(quote.estimatedWeeklyValueUsd ?? -1, 50, accuracy: 1e-9)
        XCTAssertEqual(quote.confidence, .low)
    }

    func testLiveOmpEstimateIsSaneWhenLocalDBsExist() {
        let quote = NerfTrack.loadFromOmp()
        if quote.status == .empty { return }
        if let last = quote.lastCalibratedUsd {
            XCTAssertGreaterThan(last, 1)
            XCTAssertLessThan(last, 10_000)
        }
        if let used = quote.weeklyUsedPercent {
            XCTAssertGreaterThanOrEqual(used, 0)
            XCTAssertLessThanOrEqual(used, 100)
        }
    }
}
