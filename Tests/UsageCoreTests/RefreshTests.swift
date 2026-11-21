import XCTest
@testable import UsageCore

/// A poll reads credentials only for the providers it was told to poll.
final class RefreshTests: XCTestCase {
    func testAConfigThatListsOnlyOpenRouterNeverReadsTheClaudeKeychain() async throws {
        let missingAuth = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-bar-auth-\(UUID().uuidString).json")
        let config = try loadConfig(
            #"{"providers": ["openrouter"], "piAuthFile": "\#(missingAuth.path)"}"#
        )
        let credentials = Credentials.live(
            config: config,
            keychain: { service in
                XCTFail("read the Keychain item \(service)")
                return nil
            },
            env: { _ in nil }
        )

        let poll = await Refresh.poll(config: config, credentials: credentials)

        XCTAssertNil(poll.claude)
        XCTAssertNil(poll.openCodeGo)
        XCTAssertTrue(poll.codexSeats.isEmpty)
    }
}
