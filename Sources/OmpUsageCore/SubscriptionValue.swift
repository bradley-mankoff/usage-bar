import Foundation

/// The menu-bar percent is the dollar-weighted average of weekly usage across
/// subscriptions: `sum(weeklyFraction_i * value_i) / sum(value_i)`. Weekly is
/// the only window Claude and OpenCode Go share, so their 5-hour and monthly
/// windows never skew the label.
///
/// Nobody publishes exact figures, so these are estimates from public claims,
/// picked conservatively. Anthropic explicitly does not sell subscription
/// capacity as an API-dollar equivalent.
///
/// Sources (all checked 2026-09-24):
/// - OpenCode Go $60/mo: published $12/5h, $30/wk, $60/mo request-value caps
///   (https://opencode.ai/docs/go/).
/// - Max 20x full burn = $600-1,500/mo API-equivalent (finout.io); Reddit
///   reports $2,000+ on Max $200/mo (older).
/// - Max $100 ~= 5x Pro, Max $200 ~= 10x Pro (usagebar.com, Aug 2026).
///   Pro $150 = top of the Finout range scaled to Pro (1500 / 10), below the
///   Reddit-implied $200. Max tiers follow the 5x/10x ratios.
public enum SubscriptionValue {
    public static let claudeProUsd = 150.0
    public static let claudeMax5xUsd = 750.0
    public static let claudeMax20xUsd = 1500.0
    public static let openCodeGoUsd = 60.0

    /// `plan` is Claude Code's `subscriptionType` ("pro", "max"); `tier` is its
    /// `rateLimitTier` (e.g. "default_claude_max_20x"), which tells the Max tiers apart.
    public static func claudeUsd(plan: String?, tier: String?) -> Double {
        guard (plan ?? "").lowercased().contains("max") else { return claudeProUsd }
        return (tier ?? "").contains("20x") ? claudeMax20xUsd : claudeMax5xUsd
    }

    /// Dollar-weighted average weekly used fraction. Nil when no subscription
    /// has a weekly window.
    public static func weightedWeeklyFraction(_ subs: [SubscriptionUsage]) -> Double? {
        let items = subs.compactMap { sub in sub.weeklyFraction.map { ($0, sub.monthlyValueUsd) } }
        let total = items.reduce(0.0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        return items.reduce(0.0) { $0 + $1.0 * $1.1 } / total
    }
}
