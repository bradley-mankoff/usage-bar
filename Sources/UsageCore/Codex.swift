import Foundation
import SQLite3

/// ChatGPT subscription seats (Plus, Business, ...), one card per login.
///
/// Credentials come from omp's local credential store: one `openai-codex`
/// row per signed-in seat. ChatGPT's own tokens are OAuth (access +
/// refresh); when the stored access token is expired the bar refreshes it
/// the same way omp does, so the bar keeps working without omp running.
/// Usage comes from ChatGPT's backend usage endpoint with that token.
/// Keys and tokens are never logged or written anywhere by the bar.
public enum Codex {
    public struct Seat: Equatable, Sendable {
        public let email: String
        public let accountId: String
        public let accessToken: String
        public let refreshToken: String
        public let expiresAt: Date

        public init(email: String, accountId: String, accessToken: String, refreshToken: String, expiresAt: Date) {
            self.email = email
            self.accountId = accountId
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
        }

        public var isExpired: Bool { expiresAt <= Date() }
    }

    /// The public Codex CLI's OAuth client id (open-source codex repo).
    /// Only used for refreshing; a wrong id just makes refresh fail and the
    /// stored access token is tried as-is.
    static let clientId = "app_EMoamEEZ73f0CKWBarQMYQ9aHoQPYhFv"
    static let tokenURL = "https://auth.openai.com/oauth/token"
    static let usageURL = "https://chatgpt.com/backend-api/wham/usage"

    /// Every signed-in seat on this machine. Empty when omp never signed in
    /// here; the caller hides the Codex section in that case.
    public static func loadSeats(agentDB: URL? = nil) -> [Seat] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = (agentDB ?? home.appendingPathComponent(".omp/agent/agent.db")).path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT data FROM auth_credentials WHERE provider = 'openai-codex'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var seats: [Seat] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let text = sqlite3_column_text(stmt, 0),
                  let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8)) as? [String: Any],
                  let access = obj["access"] as? String, !access.isEmpty,
                  let refresh = obj["refresh"] as? String, !refresh.isEmpty
            else { continue }
            let email = (obj["email"] as? String)?.isEmpty == false ? (obj["email"] as? String)! : "unknown seat"
            let accountId = obj["accountId"] as? String ?? ""
            let expires = (obj["expires"] as? NSNumber)?.doubleValue ?? 0
            seats.append(Seat(
                email: email,
                accountId: accountId,
                accessToken: access,
                refreshToken: refresh,
                expiresAt: Date(timeIntervalSince1970: expires / 1000)
            ))
        }
        return seats.sorted { $0.email < $1.email }
    }

    public static func fetch(seat: Seat) async throws -> SubscriptionUsage {
        let token = seat.isExpired ? (try? await refreshedAccessToken(seat)) ?? seat.accessToken : seat.accessToken
        var headers = ["Authorization": "Bearer \(token)"]
        if !seat.accountId.isEmpty { headers["ChatGPT-Account-Id"] = seat.accountId }
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
            monthlyValueUsd: 0,
            windows: windows,
            note: note
        )
    }

    /// monthlyValueUsd is 0 (unknown) so seats never feed the weighted label;
    /// see SubscriptionValue.
    static func refreshedAccessToken(_ seat: Seat) async throws -> String {
        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Double?
        }
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: seat.refreshToken),
            URLQueryItem(name: "client_id", value: clientId),
        ]
        var request = URLRequest(url: URL(string: tokenURL)!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.query?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)
        else { throw UsageError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "Codex token refresh") }
        return decoded.access_token
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
        let specs: [(key: String, label: String, isWeekly: Bool)] = [
            ("primary_window", "5 Hour", false),
            ("secondary_window", "Weekly", true),
        ]
        let windows = specs.compactMap { spec -> UsageWindow? in
            guard let window = rate[spec.key] as? [String: Any],
                  let percent = (window["used_percent"] as? NSNumber)?.doubleValue
            else { return nil }
            var reset: Date?
            if let epoch = (window["reset_at"] as? NSNumber)?.doubleValue {
                reset = Date(timeIntervalSince1970: epoch > 1e11 ? epoch / 1000 : epoch)
            }
            return UsageWindow(
                id: "openai-codex:\(spec.key)",
                label: spec.label,
                usedFraction: percent / 100,
                resetsAt: reset,
                isWeekly: spec.isWeekly
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
