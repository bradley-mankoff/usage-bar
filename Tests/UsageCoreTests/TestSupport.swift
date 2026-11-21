import Foundation
@testable import UsageCore

/// Writes `json` to a temporary file and loads it exactly as the app loads
/// `~/.config/usage-bar/config.json`, so tests exercise the file seam.
func loadConfig(_ json: String) throws -> Config {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("usage-bar-config-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return Config.load(from: url)
}

/// A committed fixture file next to the tests.
func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent(name)
}
