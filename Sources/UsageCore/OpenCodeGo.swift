import Foundation

/// OpenCode Go subscription limits, read with the API key pi stores in the
/// configured auth.json. Same endpoint omp used before it was retired.
public enum OpenCodeGo {
    static let usageURL = "https://opencode.ai/zen/go/v1/usage"

    static let windows: [(key: String, label: String)] = [
        ("rolling", "5 Hour"),
        ("weekly", "Weekly"),
        ("monthly", "Monthly"),
    ]

    /// The two windows the menu bar shows, in display order: the rolling then
    /// the weekly. The monthly window stays in the dropdown.
    static let menuBarWindowIDs = windows.prefix(2).map(\.key)

    static func fetch(credentials: Credentials) async throws -> SubscriptionUsage {
        guard let key = credentials.piApiKey(provider: "opencode-go") else {
            throw UsageError.missingCredential("no opencode-go key in pi's auth.json")
        }
        let body = try await HTTP.get(usageURL, headers: [
            "Authorization": "Bearer \(key)",
            "Accept": "application/json",
        ], what: "OpenCode Go usage")
        return SubscriptionUsage(
            name: "OpenCode Go",
            plan: nil,
            windows: try parse(body)
        )
    }

    /// Response shape: `{"usage": {"weekly": {"percent": 4, "resetsAt": "…"}, …}}`.
    public static func parse(_ data: Data) throws -> [UsageWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any]
        else { throw UsageError.badResponse("OpenCode Go usage") }
        return windows.compactMap { spec in
            guard let window = usage[spec.key] as? [String: Any],
                  let percent = (window["percent"] as? NSNumber)?.doubleValue
            else { return nil }
            return UsageWindow(
                id: spec.key,
                label: spec.label,
                usedFraction: percent / 100,
                resetsAt: parseISODate(window["resetsAt"] as? String)
            )
        }
    }
}
