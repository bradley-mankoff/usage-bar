import Foundation
import SwiftUI
import UsageCore

/// One Codex seat on this machine, labeled by its login email.
struct CodexSeatState: Identifiable {
    var id: String { email }
    let email: String
    var result: Result<SubscriptionUsage, Error>?
}

@MainActor
final class UsageStore: ObservableObject {
    /// Nil means hide the section: no credential on this machine (loading is
    /// tracked separately by firstFetchDone). A present Result, ok or not,
    /// always renders.
    @Published var claude: Result<SubscriptionUsage, Error>?
    @Published var openCodeGo: Result<SubscriptionUsage, Error>?
    @Published var openRouter: Result<OpenRouter.Credits, Error>?
    @Published var codexSeats: [CodexSeatState] = []
    @Published var firstFetchDone = false
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
            + codexSeats.compactMap { try? $0.result?.get() }.filter { $0.monthlyValueUsd > 0 }
    }

    /// Dollar-weighted weekly percent across subscriptions with a known value
    /// (see SubscriptionValue), then OpenRouter's remaining dollars, e.g.
    /// `25% · $16.62`. OpenRouter never feeds the percent: it has no window.
    /// Codex seats are cards only until their Business value is known.
    var barLabel: String {
        var parts: [String] = []
        if let frac = SubscriptionValue.weightedWeeklyFraction(subscriptions) {
            let pct = frac * 100
            parts.append(pct < 10 ? String(format: "%.1f%%", pct) : String(format: "%.0f%%", pct))
        }
        if let credits = try? openRouter?.get(), credits.totalCredits > 0 {
            parts.append(String(format: "$%.2f", credits.remaining))
        }
        if parts.isEmpty { return firstFetchDone ? "?" : "…" }
        return parts.joined(separator: " · ")
    }

    func refresh() {
        Task {
            async let claude = Self.capture { try await Claude.fetch() }
            async let go = Self.capture { try await OpenCodeGo.fetch() }
            async let credits = Self.capture { try await OpenRouter.fetch() }
            let seats = await Task.detached(priority: .utility) { Codex.loadSeats() }.value
            var seatResults: [(String, Result<SubscriptionUsage, Error>?)] = []
            await withTaskGroup(of: (String, Result<SubscriptionUsage, Error>?).self) { group in
                for seat in seats {
                    group.addTask {
                        await (seat.email, Self.capture { try await Codex.fetch(seat: seat) })
                    }
                }
                for await row in group { seatResults.append(row) }
            }
            (self.claude, self.openCodeGo, self.openRouter) = await (claude, go, credits)
            self.codexSeats = seatResults
                .sorted { $0.0 < $1.0 }
                .map { CodexSeatState(email: $0.0, result: $0.1) }
            lastUpdated = Date()
            firstFetchDone = true
        }
    }

    /// Not authed (no credential, expired sign-in, rejected token) hides
    /// the section; any other failure renders. So a dead seat vanishes
    /// instead of showing an error card.
    nonisolated private static func capture<T>(_ body: @Sendable () async throws -> T) async -> Result<T, Error>? {
        do { return .success(try await body()) } catch {
            if let usage = error as? UsageError {
                switch usage {
                case .missingCredential, .reauth: return nil
                case .http(let status, _) where status == 401 || status == 403: return nil
                default: break
                }
            }
            return .failure(error)
        }
    }
}
