import XCTest
import Foundation
@testable import UsageCore

/// Every test here loads a config the way the app does: from a JSON file.
final class ConfigTests: XCTestCase {
    func testNoConfigFileMeansEveryProviderAndClaudeInTheBar() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-bar-\(UUID().uuidString).json")

        let config = Config.load(from: missing)

        XCTAssertEqual(config.providers, [.claude, .openCodeGo, .codex, .openRouter])
        XCTAssertEqual(config.menuBar, .claude)
        XCTAssertEqual(
            config.piAuthFile.path,
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".pi/agent/auth.json").path
        )
        XCTAssertEqual(config.refreshSeconds, 300)
        XCTAssertEqual(config.links, [])
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
