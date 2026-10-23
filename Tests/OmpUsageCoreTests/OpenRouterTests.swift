import XCTest
@testable import OmpUsageCore

final class OpenRouterTests: XCTestCase {
    func testRemainingIsTotalMinusUsage() {
        let credits = OpenRouter.Credits(totalCredits: 20, totalUsage: 2.72)
        XCTAssertEqual(credits.remaining, 17.28, accuracy: 1e-9)
        XCTAssertEqual(credits.usedFraction ?? -1, 0.136, accuracy: 1e-9)
    }

    func testZeroTotalHasNoFraction() {
        let credits = OpenRouter.Credits(totalCredits: 0, totalUsage: 0)
        XCTAssertNil(credits.usedFraction)
    }
}
