import Foundation

/// One Codex seat's result in a poll.
public struct SeatPoll: Sendable, Identifiable {
    public var id: String { email }
    public var email: String
    public var result: Result<SubscriptionUsage, Error>?

    public init(email: String, result: Result<SubscriptionUsage, Error>?) {
        self.email = email
        self.result = result
    }
}

/// The results of one poll: one entry per card the bar can draw. A provider the
/// config does not list, or whose credential is missing or rejected, is nil.
public struct Poll: Sendable {
    public var claude: Result<SubscriptionUsage, Error>?
    public var openCodeGo: Result<SubscriptionUsage, Error>?
    public var openRouter: Result<OpenRouter.Credits, Error>?
    public var codexSeats: [SeatPoll]

    public init(
        claude: Result<SubscriptionUsage, Error>? = nil,
        openCodeGo: Result<SubscriptionUsage, Error>? = nil,
        openRouter: Result<OpenRouter.Credits, Error>? = nil,
        codexSeats: [SeatPoll] = []
    ) {
        self.claude = claude
        self.openCodeGo = openCodeGo
        self.openRouter = openRouter
        self.codexSeats = codexSeats
    }
}

/// Polls the providers the config lists, reading only their credentials.
public enum Refresh {
    /// Polls this Mac's providers the way the app does.
    public static func poll(config: Config) async -> Poll {
        await poll(config: config, credentials: .live(config: config))
    }

    static func poll(config: Config, credentials: Credentials) async -> Poll {
        async let claude = optionalResult(.claude, in: config) {
            try await Claude.fetch(credentials: credentials)
        }
        async let go = optionalResult(.openCodeGo, in: config) {
            try await OpenCodeGo.fetch(credentials: credentials)
        }
        async let credits = optionalResult(.openRouter, in: config) {
            try await OpenRouter.fetch(credentials: credentials)
        }

        var seats: [SeatPoll] = []
        if config.providers.contains(.codex) {
            let logins = Codex.loadSeats(from: credentials)
            await withTaskGroup(of: SeatPoll.self) { group in
                for seat in logins {
                    group.addTask {
                        SeatPoll(
                            email: seat.email,
                            result: await capture { try await Codex.fetch(seat: seat) }
                        )
                    }
                }
                for await seat in group { seats.append(seat) }
            }
        }

        return Poll(
            claude: await claude,
            openCodeGo: await go,
            openRouter: await credits,
            codexSeats: seats.sorted { $0.email < $1.email }
        )
    }

    /// Nil when the provider is not configured, so an unlisted provider is
    /// never fetched and its credentials are never read.
    private static func optionalResult<T>(
        _ provider: Config.Provider, in config: Config,
        _ body: @escaping @Sendable () async throws -> T
    ) async -> Result<T, Error>? {
        guard config.providers.contains(provider) else { return nil }
        return await capture(body)
    }

    /// Not authed (no credential, expired sign-in, rejected token) hides the
    /// card; any other failure renders. So a dead seat vanishes instead of
    /// showing an error card.
    nonisolated private static func capture<T>(
        _ body: @Sendable () async throws -> T
    ) async -> Result<T, Error>? {
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
