import Foundation

/// Claude subscription limits, read with Claude Code's own OAuth token.
///
/// pi reaches Claude through the claude-bridge provider, which drives Claude
/// Code, so the token lives in Claude Code's Keychain item
/// ("Claude Code-credentials"). The bar only reads it; Claude Code refreshes
/// it whenever it runs, so an expired token is reported, not refreshed.
public enum Claude {
    static let usageURL = "https://api.anthropic.com/api/oauth/usage"

    /// Windows shown, in display order. The API also returns many codenamed
    /// fields (promotions, experiments); those are ignored.
    static let windows: [(key: String, label: String, isWeekly: Bool)] = [
        ("five_hour", "5 Hour", false),
        ("seven_day", "Weekly", true),
        ("seven_day_opus", "Weekly Opus", true),
        ("seven_day_sonnet", "Weekly Sonnet", true),
    ]

    public static func fetch() async throws -> SubscriptionUsage {
        guard let json = Credentials.keychain(service: "Claude Code-credentials"),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw UsageError.missingCredential("Claude Code is not signed in") }
        if let expires = oauth["expiresAt"] as? Double, expires / 1000 < Date().timeIntervalSince1970 {
            throw UsageError.missingCredential("Claude Code token expired; run Claude Code to refresh it")
        }
        let plan = oauth["subscriptionType"] as? String
        let tier = oauth["rateLimitTier"] as? String
        let body = try await HTTP.get(usageURL, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
        ], what: "Claude usage")
        return SubscriptionUsage(
            name: "Claude",
            plan: plan.map { $0.capitalized },
            monthlyValueUsd: SubscriptionValue.claudeUsd(plan: plan, tier: tier),
            windows: try parse(body)
        )
    }

    /// `utilization` is a percent (0-100); a window is null when the plan
    /// doesn't have it.
    public static func parse(_ data: Data) throws -> [UsageWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse("Claude usage")
        }
        return windows.compactMap { spec in
            guard let window = root[spec.key] as? [String: Any],
                  let percent = (window["utilization"] as? NSNumber)?.doubleValue
            else { return nil }
            return UsageWindow(
                id: spec.key,
                label: spec.label,
                usedFraction: percent / 100,
                resetsAt: parseISODate(window["resets_at"] as? String),
                isWeekly: spec.isWeekly
            )
        }
    }
}
