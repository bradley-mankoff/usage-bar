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
    /// The last successful Claude result, or nil until the first success. A
    /// failed poll leaves it alone (see `Claude.keepingLastGood`), so the
    /// dropdown card and menu bar keep the last good numbers. A present
    /// Result always renders.
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

    /// Claude's five-hour then weekly percent (see MenuBarLabel). Other
    /// providers appear only in the dropdown, so they cannot change it.
    var barLabel: String {
        MenuBarLabel.text(
            claudeWindows: try? claude?.get().windows,
            firstFetchDone: firstFetchDone
        )
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
            let (claudePoll, goPoll, creditsPoll) = await (claude, go, credits)
            self.claude = Claude.keepingLastGood(self.claude, after: claudePoll)
            self.openCodeGo = goPoll
            self.openRouter = creditsPoll
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
