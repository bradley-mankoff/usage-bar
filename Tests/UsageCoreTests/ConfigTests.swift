import XCTest
import Foundation
@testable import UsageCore

/// Every test here loads a config the way the app does: from a JSON file.
final class ConfigTests: XCTestCase {
    func testWithNoConfigFileEveryProviderIsPolledInItsUsualOrder() {
        let config = Config.load(from: missingConfigFile())

        XCTAssertEqual(config.providers, [.claude, .openCodeGo, .codex, .openRouter])
    }

    func testWithNoConfigFileTheBarLabelsItselfWithClaude() {
        let config = Config.load(from: missingConfigFile())

        XCTAssertEqual(config.menuBar, .claude)
    }

    func testWithNoConfigFileTheBarReadsPisAuthFile() {
        let config = Config.load(from: missingConfigFile())

        XCTAssertEqual(config.piAuthFile.path, NSHomeDirectory() + "/.pi/agent/auth.json")
    }

    func testWithNoConfigFileTheBarRefreshesEveryFiveMinutes() {
        let config = Config.load(from: missingConfigFile())

        XCTAssertEqual(config.refreshSeconds, 300)
    }

    func testWithNoConfigFileTheBarShowsNoLink() {
        let config = Config.load(from: missingConfigFile())

        XCTAssertEqual(config.links, [])
    }

    /// A path under the temporary directory that nothing is written to, so
    /// `Config.load` sees the no-file case.
    private func missingConfigFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-bar-\(UUID().uuidString).json")
    }

    func testProvidersComeFromTheConfigInItsOrder() throws {
        let config = try loadConfig(#"{"providers": ["openrouter", "claude"]}"#)

        XCTAssertEqual(config.providers, [.openRouter, .claude])
    }

    func testTheConfigChoosesTheMenuBarProvider() throws {
        let config = try loadConfig(#"{"menuBar": "opencode-go"}"#)

        XCTAssertEqual(config.menuBar, .openCodeGo)
    }

    func testRefreshSecondsComeFromTheConfig() throws {
        let config = try loadConfig(#"{"refreshSeconds": 60}"#)

        XCTAssertEqual(config.refreshSeconds, 60)
    }
}
