import Foundation
import SwiftUI
import OmpUsageCore

@MainActor
final class UsageStore: ObservableObject {
    /// Nil until the first fetch finishes; each provider fails on its own.
    @Published var claude: Result<SubscriptionUsage, Error>?
    @Published var openCodeGo: Result<SubscriptionUsage, Error>?
    @Published var openRouter: Result<OpenRouter.Credits, Error>?
    @Published var lastUpdated: Date?
    private var timer: Timer?
    private let refreshInterval: TimeInterval = 300

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var subscriptions: [SubscriptionUsage] {
        [claude, openCodeGo].compactMap { try? $0?.get() }
    }

    /// Dollar-weighted weekly percent across subscriptions (see
    /// SubscriptionValue), then OpenRouter's remaining dollars, e.g.
    /// `25% · $16.62`. OpenRouter never feeds the percent: it has no window.
    var barLabel: String {
        var parts: [String] = []
        if let frac = SubscriptionValue.weightedWeeklyFraction(subscriptions) {
            let pct = frac * 100
            parts.append(pct < 10 ? String(format: "%.1f%%", pct) : String(format: "%.0f%%", pct))
        }
        if let credits = try? openRouter?.get(), credits.totalCredits > 0 {
            parts.append(String(format: "$%.2f", credits.remaining))
        }
        if parts.isEmpty { return lastUpdated == nil ? "…" : "?" }
        return parts.joined(separator: " · ")
    }

    func refresh() {
        Task {
            async let claude = Self.capture { try await Claude.fetch() }
            async let go = Self.capture { try await OpenCodeGo.fetch() }
            async let credits = Self.capture { try await OpenRouter.fetch() }
            (self.claude, self.openCodeGo, self.openRouter) = await (claude, go, credits)
            lastUpdated = Date()
        }
    }

    nonisolated private static func capture<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}
