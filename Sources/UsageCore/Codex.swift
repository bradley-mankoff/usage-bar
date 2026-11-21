import Foundation

/// ChatGPT subscription seats (Plus, Business, ...), one card per login.
///
/// Credentials come from the configured pi auth.json: the built-in `openai-codex` login
/// and any `codex-<name>` login that the chatgpt-seats extension adds, one
/// per seat of a shared workspace. Usage comes from ChatGPT's backend usage
/// endpoint with that login's access token. The bar never refreshes a token:
/// rotating pi's refresh token would sign pi out, so an expired seat stays
/// hidden until pi next uses it. Keys and tokens are never logged or written
/// anywhere by the bar.
public enum Codex {
    public struct Seat: Equatable, Sendable {
        public let email: String
        public let accountId: String
        public let accessToken: String
        public let expiresAt: Date

        public init(email: String, accountId: String, accessToken: String, expiresAt: Date) {
            self.email = email
            self.accountId = accountId
            self.accessToken = accessToken
            self.expiresAt = expiresAt
        }

        public var isExpired: Bool { expiresAt <= Date() }
    }

    static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    /// The list the Codex CLI reads for banked resets. Only GET it: the
    /// `/consume` path under it spends one.
    static let resetCreditsURL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"

    /// The two windows Codex reports, in display order.
    static let windows: [(key: String, label: String)] = [
        ("primary_window", "5 Hour"),
        ("secondary_window", "Weekly"),
    ]

    /// The two windows the menu bar shows, named as `parse` emits them.
    static let menuBarWindowIDs = windows.prefix(2).map { windowID(for: $0.key) }

    /// The id of one window. Every seat reports the same two windows, so the
    /// id carries no seat and the menu bar can read it without knowing one.
    static func windowID(for key: String) -> String { "openai-codex:\(key)" }

    /// Every ChatGPT login in pi's auth.json. Empty when pi has none; the
    /// caller hides the Codex section in that case.
    static func loadSeats(from credentials: Credentials) -> [Seat] {
        seats(fromPiAuth: credentials.piAuth)
    }

    static func seats(fromPiAuth auth: [String: [String: Any]]) -> [Seat] {
        auth.compactMap { provider, entry -> Seat? in
            guard provider == "openai-codex" || provider.hasPrefix("codex-"),
                  let access = entry["access"] as? String, !access.isEmpty
            else { return nil }
            let expires = (entry["expires"] as? NSNumber)?.doubleValue ?? 0
            return Seat(
                email: email(fromAccessToken: access) ?? provider,
                accountId: entry["accountId"] as? String ?? "",
                accessToken: access,
                expiresAt: Date(timeIntervalSince1970: expires / 1000)
            )
        }
        .sorted { $0.email < $1.email }
    }

    /// pi does not store the seat's email, but ChatGPT's access token is a
    /// JWT whose profile claim carries it.
    static func email(fromAccessToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = claims["https://api.openai.com/profile"] as? [String: Any],
              let email = profile["email"] as? String, !email.isEmpty
        else { return nil }
        return email
    }

    public static func fetch(seat: Seat) async throws -> SubscriptionUsage {
        if seat.isExpired { throw UsageError.reauth("Codex") }
        let headers = ["Authorization": "Bearer \(seat.accessToken)"]
            .merging(seat.accountId.isEmpty ? [:] : ["ChatGPT-Account-Id": seat.accountId]) { $1 }
        // The usage card matters more than the resets, so a failed resets
        // fetch shows no resets rather than an error.
        async let resetBody = try? HTTP.get(resetCreditsURL, headers: headers, what: "Codex resets")
        let body: Data
        do {
            body = try await HTTP.get(usageURL, headers: headers, what: "Codex usage")
        } catch let error as UsageError {
            if case .http(let status, _) = error, status == 401 || status == 403 {
                throw UsageError.reauth("Codex")
            }
            throw error
        }
        let (windows, note) = try parse(body)
        return SubscriptionUsage(
            name: "Codex",
            plan: seat.email,
            windows: windows,
            note: note,
            resetCredits: await resetBody.map(parseResetCredits) ?? []
        )
    }

    /// Shape confirmed against the live endpoint 2026-11-05: `{"credits":
    /// [{"status": "available", "title": "Full reset (Weekly + 5 hr)",
    /// "expires_at": "2026-11-06T23:53:33.856823Z", ...}], "available_count": 3}`.
    /// Redeemed and expired credits stay in the list, so only available ones count.
    public static func parseResetCredits(_ data: Data) -> [ResetCredit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let credits = root["credits"] as? [[String: Any]]
        else { return [] }
        return credits
            .filter { ($0["status"] as? String) == "available" }
            .map { ResetCredit(title: $0["title"] as? String ?? "Reset", expiresAt: parseISODate($0["expires_at"] as? String)) }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    /// Shape confirmed against the live endpoint 2026-10-23 (both seats of a
    /// Business workspace); see UsageTests fixtures. `used_percent` is 0-100
    /// and `reset_at` is epoch seconds.
    public static func parse(_ data: Data) throws -> (windows: [UsageWindow], note: String?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = root["rate_limit"] as? [String: Any]
        else {
            throw UsageError.badResponse("Codex usage")
        }
        let windows = Self.windows.compactMap { spec -> UsageWindow? in
            guard let window = rate[spec.key] as? [String: Any],
                  let percent = (window["used_percent"] as? NSNumber)?.doubleValue
            else { return nil }
            var reset: Date?
            if let epoch = (window["reset_at"] as? NSNumber)?.doubleValue {
                reset = Date(timeIntervalSince1970: epoch > 1e11 ? epoch / 1000 : epoch)
            }
            return UsageWindow(
                id: windowID(for: spec.key),
                label: spec.label,
                usedFraction: percent / 100,
                resetsAt: reset
            )
        }
        var note: String?
        if let upsell = root["rate_limit_upsell"] as? [String: Any],
           let description = upsell["description"] as? String, !description.isEmpty
        {
            note = description
        } else if (rate["limit_reached"] as? Bool) == true {
            note = "Limit reached."
        }
        return (windows, note)
    }
}
