import Foundation

/// The menu-bar % is the dollar-weighted average of weekly usage across linked
/// subscriptions: `sum(weeklyFraction_i * value_i) / sum(value_i)`. Weekly is
/// the only window all three subscriptions share (Go `weekly`/`7d`, xAI `1w`,
/// Anthropic `anthropic:7d`), so 5h/monthly windows never skew the label.
///
/// Nobody publishes exact figures, so these are estimates from public claims,
/// picked conservatively. Anthropic explicitly does not sell subscription
/// capacity as an API-dollar equivalent.
///
/// Sources (all checked 2026-09-24):
/// - OpenCode Go $60/mo cap: published $12/5h, $30/wk, $60/mo estimated
///   request-value caps (https://opencode.ai/docs/go/).
/// - Opus 5.5 API $4/M input, $20/M output; Pro $20/mo, Max 5x $100/mo,
///   Max 20x $200/mo (Anthropic pricing docs via eesel.ai, 2026-09-23).
/// - Max 20x full burn = $600-1,500/mo API-equiv (finout.io, ~2w ago);
///   Reddit reports $2,000+ on Max $200/mo (older).
/// - Max $100 ~= 5x Pro, Max $200 ~= 10x Pro (usagebar.com, Aug 2026).
///   Pro $150 = top of the Finout range scaled to Pro (1500 / 10),
///   below the Reddit-implied $200. Max tiers follow the 5x/10x ratios.
/// - SuperGrok $30/mo with ~2M tokens/day cap (pricepertoken.com, Jun 2026);
///   at Grok 4.6/4.7 API rates $2/$6 (felloai.com, 2026-09-23) that cap is
///   ~$120/mo input-weighted to ~$360/mo output-weighted. $200 is the
///   conservative middle. xAI moved to an unpublished weekly pool Jun 2026,
///   so this anchor is the softest one here.
public enum SubscriptionValue {
    public static let anthropicProUsd = 150.0
    public static let anthropicMax5xUsd = 750.0
    public static let anthropicMax20xUsd = 1500.0
    public static let xaiSuperGrokUsd = 200.0

    /// Monthly API-equivalent USD for a fully-used subscription. Nil for
    /// providers with no subscription meter (pay-as-you-go, unknown).
    /// omp currently sends no planType for anthropic/xai, so those default
    /// to the base tier (this user is claude_pro per the Anthropic bootstrap
    /// API; SuperGrok $30/mo is the common xAI tier).
    public static func valueUsd(provider: String, planType: String?) -> Double? {
        switch provider {
        case "opencode-go":
            return GoCatalog.monthlyPoolUsd
        case "xai-oauth":
            return xaiSuperGrokUsd
        case "anthropic":
            let plan = (planType ?? "").lowercased()
            if plan.contains("max") {
                return plan.contains("20") ? anthropicMax20xUsd : anthropicMax5xUsd
            }
            return anthropicProUsd
        default:
            return nil
        }
    }
    /// Weekly usedFraction for one provider report. Picks the highest
    /// usedFraction among weekly windows (window id `7d`/`1w`, or limit ids
    /// containing `:7d`/`:1w`). Nil when the report has no weekly window.
    public static func weeklyFraction(limits: [(windowId: String?, limitId: String, usedFraction: Double?)]) -> Double? {
        limits.filter { isWeekly(windowId: $0.windowId, limitId: $0.limitId) }
            .compactMap { $0.usedFraction }.max()
    }

    public static func isWeekly(windowId: String?, limitId: String) -> Bool {
        let w = (windowId ?? "").lowercased()
        if w == "7d" || w == "1w" || w == "week" || w == "weekly" { return true }
        let id = limitId.lowercased()
        return id == "weekly" || id.contains(":7d") || id.contains(":1w")
    }

    /// Dollar-weighted average used fraction. Nil when there is nothing to
    /// weight (caller falls back to the max-fraction label).
    public static func weightedFraction(_ items: [(usedFraction: Double, valueUsd: Double)]) -> Double? {
        let total = items.reduce(0.0) { $0 + $1.valueUsd }
        guard total > 0 else { return nil }
        return items.reduce(0.0) { $0 + $1.usedFraction * $1.valueUsd } / total
    }
}
