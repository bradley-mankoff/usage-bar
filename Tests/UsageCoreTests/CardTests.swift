import XCTest
@testable import UsageCore

/// What the dropdown shows, in order, for a config.
final class CardTests: XCTestCase {
    func testTheDefaultCardsAreEveryProviderInTodaysOrderAndNoLink() {
        let cards = Config.default.cards(codexSeats: ["a-seat@example.com"])

        XCTAssertEqual(cards, [
            .claude,
            .openCodeGo,
            .codexSeat(email: "a-seat@example.com"),
            .openRouter,
        ])
    }

    func testAConfigThatListsOnlyOpenRouterShowsOnlyOpenRouter() throws {
        let config = try loadConfig(#"{"providers": ["openrouter"]}"#)

        let cards = config.cards(codexSeats: ["a-seat@example.com"])

        XCTAssertEqual(cards, [.openRouter])
    }

    func testALinksEntryBecomesACardThatOpensItsURL() throws {
        let config = try loadConfig(
            #"{"providers": [], "links": [{"title": "Provider console", "url": "https://example.com/usage"}]}"#
        )

        let cards = config.cards(codexSeats: [])

        XCTAssertEqual(cards, [
            .link(Config.Link(
                title: "Provider console",
                url: URL(string: "https://example.com/usage")!
            )),
        ])
    }
}
