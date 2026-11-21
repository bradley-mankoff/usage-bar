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
    /// What the bar shows and where it reads from.
    let config: Config
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

    init(config: Config = Config.load()) {
        self.config = config
        refresh()
        timer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(config.refreshSeconds), repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// The dropdown's cards, in config order, then the config's links.
    var cards: [Card] {
        config.cards(codexSeats: codexSeats.map(\.email))
    }

    /// The configured provider's windows come from that provider's result, so
    /// no other provider can change the text.
    var barLabel: String {
        MenuBarLabel.text(
            provider: config.menuBar,
            windows: menuBarWindows,
            firstFetchDone: firstFetchDone
        )
    }

    private var menuBarWindows: [UsageWindow]? {
        switch config.menuBar {
        case .claude:
            guard case .success(let usage)? = claude else { return nil }
            return usage.windows
        case .openCodeGo:
            guard case .success(let usage)? = openCodeGo else { return nil }
            return usage.windows
        case .codex:
            guard let result = codexSeats.first?.result, case .success(let usage) = result else {
                return nil
            }
            return usage.windows
        case .openRouter:
            guard case .success(let credits)? = openRouter, let window = credits.window else {
                return nil
            }
            return [window]
        }
    }

    func refresh() {
        Task {
            let poll = await Refresh.poll(config: config)
            self.claude = Claude.keepingLastGood(self.claude, after: poll.claude)
            self.openCodeGo = poll.openCodeGo
            self.openRouter = poll.openRouter
            self.codexSeats = poll.codexSeats.map {
                CodexSeatState(email: $0.email, result: $0.result)
            }
            lastUpdated = Date()
            firstFetchDone = true
        }
    }
}
