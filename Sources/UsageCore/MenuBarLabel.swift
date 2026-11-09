import Foundation

/// The text in the menu bar: Claude's five-hour usage percent, then its overall
/// weekly (`seven_day`) percent, e.g. `12% · 40%`. Both windows come from the
/// same Claude result, so no other provider can change the text.
public enum MenuBarLabel {
    /// The two Claude windows the bar shows, in display order. The ids must
    /// match `Claude.windows`; `seven_day` is the overall weekly window, and
    /// the per-model weekly windows stay in the dropdown.
    static let shownWindowIDs = ["five_hour", "seven_day"]

    public static func text(claudeWindows: [UsageWindow]?, firstFetchDone: Bool) -> String {
        let windows = claudeWindows ?? []
        let parts = shownWindowIDs.compactMap { id in
            windows.first { $0.id == id }.map { percent($0.usedFraction) }
        }
        guard !parts.isEmpty else { return firstFetchDone ? "?" : "\u{2026}" }
        return parts.joined(separator: " \u{00B7} ")
    }

    private static func percent(_ fraction: Double) -> String {
        let pct = fraction * 100
        return pct < 10 ? String(format: "%.1f%%", pct) : String(format: "%.0f%%", pct)
    }
}
