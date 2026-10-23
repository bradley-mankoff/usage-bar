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
        public let accessToken: String
        public let refreshToken: String
        public let expiresAt: Date

        public init(email: String, accessToken: String, refreshToken: String, expiresAt: Date) {
            self.email = email
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
    static let usageURL = "https://chatgpt.com/backend-api/codex/usage"

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
            let expires = (obj["expires"] as? NSNumber)?.doubleValue ?? 0
            seats.append(Seat(
                email: email,
                accessToken: access,
                refreshToken: refresh,
                expiresAt: Date(timeIntervalSince1970: expires / 1000)
            ))
        }
        return seats.sorted { $0.email < $1.email }
    }

    public static func fetch(seat: Seat) async throws -> SubscriptionUsage {
        let token = seat.isExpired ? (try? await refreshedAccessToken(seat)) ?? seat.accessToken : seat.accessToken
        let body: Data
        do {
            body = try await HTTP.get(usageURL, headers: [
                "Authorization": "Bearer \(token)",
            ], what: "Codex usage")
        } catch let error as UsageError {
            if case .http(let status, _) = error, status == 401 || status == 403 {
                throw UsageError.reauth("Codex")
            }
            throw error
        }
        return SubscriptionUsage(
            name: "Codex",
            plan: seat.email,
            monthlyValueUsd: 0,
            windows: try parse(body)
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

    /// Shape confirmed against the live endpoint; see UsageTests fixtures.
    public static func parse(_ data: Data) throws -> [UsageWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse("Codex usage")
        }
        let specs: [(key: String, label: String, isWeekly: Bool)] = [
            ("primary", "5 Hour", false),
            ("secondary", "Weekly", true),
        ]
        return specs.compactMap { spec in
            guard let window = root[spec.key] as? [String: Any] else { return nil }
            let fraction = (window["used_percent"] as? NSNumber)?.doubleValue
                ?? (window["utilization"] as? NSNumber).map { $0.doubleValue / 100 }
            guard let fraction else { return nil }
            return UsageWindow(
                id: "openai-codex:\(spec.key)",
                label: spec.label,
                usedFraction: fraction > 1 ? fraction / 100 : fraction,
                resetsAt: parseISODate(window["resets_at"] as? String),
                isWeekly: spec.isWeekly
            )
        }
    }
}
