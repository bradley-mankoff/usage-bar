import XCTest
@testable import UsageCore

/// The config's `piAuthFile` is the only auth file the bar reads.
final class PiAuthFileTests: XCTestCase {
    func testAPiAuthFileFromTheConfigSuppliesCodexSeats() throws {
        let config = try loadConfig(#"{"piAuthFile": "\#(fixture("pi-auth.json").path)"}"#)
        let credentials = Credentials.live(config: config, keychain: { _ in nil }, env: { _ in nil })

        let seats = Codex.loadSeats(from: credentials)

        XCTAssertEqual(seats.map(\.email), ["a-seat@example.com"])
        XCTAssertEqual(seats.map(\.accountId), ["acct-fixture"])
    }

    func testAPiAuthFileFromTheConfigSuppliesTheOpenRouterKey() throws {
        let config = try loadConfig(#"{"piAuthFile": "\#(fixture("pi-auth.json").path)"}"#)
        let credentials = Credentials.live(config: config, keychain: { _ in nil }, env: { _ in nil })

        XCTAssertEqual(OpenRouter.apiKey(from: credentials), "sk-or-fixture")
    }
}
