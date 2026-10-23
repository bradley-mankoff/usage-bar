import Foundation

/// OpenCode Go subscription limits, read with the API key pi stores in
/// `~/.pi/agent/auth.json`. Same endpoint omp used.
public enum OpenCodeGo {
    static let usageURL = "https://opencode.ai/zen/go/v1/usage"

    static let windows: [(key: String, label: String, isWeekly: Bool)] = [
        ("rolling", "5 Hour", false),
        ("weekly", "Weekly", true),
        ("monthly", "Monthly", false),
    ]

    public static func fetch() async throws -> SubscriptionUsage {
        guard let key = Credentials.piApiKey(provider: "opencode-go") else {
            throw UsageError.missingCredential("no opencode-go key in pi's auth.json")
        }
        let body = try await HTTP.get(usageURL, headers: [
            "Authorization": "Bearer \(key)",
            "Accept": "application/json",
        ], what: "OpenCode Go usage")
        return SubscriptionUsage(
            name: "OpenCode Go",
            plan: nil,
            monthlyValueUsd: SubscriptionValue.openCodeGoUsd,
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
                resetsAt: parseISODate(window["resetsAt"] as? String),
                isWeekly: spec.isWeekly
            )
        }
    }
}
