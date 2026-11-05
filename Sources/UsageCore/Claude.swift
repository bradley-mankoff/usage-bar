import Foundation

/// Claude subscription limits, read with an OAuth token someone else keeps fresh.
///
/// Two places hold one: pi's `anthropic` login in auth.json (pi refreshes it
/// when it talks to Claude directly, as on the work Mac) and Claude Code's
/// Keychain item "Claude Code-credentials" (Claude Code refreshes it when it
/// runs, as under pi's claude-bridge on the home Mac). Whichever token is
/// unexpired wins. The bar never refreshes either: rotating a refresh token
/// it does not own would sign its owner out.
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
        let pi = Credentials.piAuth()["anthropic"]
        let claudeCode = Credentials.keychain(service: "Claude Code-credentials")
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            .flatMap { $0["claudeAiOauth"] as? [String: Any] }
        let now = Date().timeIntervalSince1970 * 1000
        let candidates: [(token: String?, expiresMs: Double?)] = [
            (pi?["access"] as? String, (pi?["expires"] as? NSNumber)?.doubleValue),
            (claudeCode?["accessToken"] as? String, (claudeCode?["expiresAt"] as? NSNumber)?.doubleValue),
        ]
        guard let token = candidates.first(where: { $0.token != nil && ($0.expiresMs ?? .infinity) > now })?.token else {
            throw UsageError.missingCredential("no unexpired Claude token in pi or Claude Code")
        }
        // Only Claude Code records the plan; pi's login does not, which values it as Pro.
        let plan = claudeCode?["subscriptionType"] as? String
        let tier = claudeCode?["rateLimitTier"] as? String
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
