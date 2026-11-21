import Foundation

/// The text in the menu bar: the configured provider's first two windows, in
/// display order, e.g. Claude's five-hour and weekly as `12% · 40%`. Both
/// windows come from the same provider's result, so no other provider can
/// change the text.
public enum MenuBarLabel {
    public static func text(
        provider: Config.Provider, windows: [UsageWindow]?, firstFetchDone: Bool
    ) -> String {
        let windows = windows ?? []
        let parts = provider.menuBarWindowIDs.compactMap { id in
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
