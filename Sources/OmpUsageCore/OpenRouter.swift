import Foundation
import SQLite3

/// OpenRouter pay-as-you-go credits.
///
/// `omp usage --json` reports API-key providers as "no usage data"
/// (`accountsWithoutUsage`), so the widget queries OpenRouter directly.
/// The key is read from the same places omp uses: `OPENROUTER_API_KEY`
/// first, then the `openrouter` row in omp's local credential store.
/// The key itself is never logged or persisted — only the fetched totals.
public enum OpenRouter {
    public struct Credits: Equatable, Sendable {
        public let totalCredits: Double
        public let totalUsage: Double

        public init(totalCredits: Double, totalUsage: Double) {
            self.totalCredits = totalCredits
            self.totalUsage = totalUsage
        }

        public var remaining: Double { totalCredits - totalUsage }

        public var usedFraction: Double? {
            guard totalCredits > 0 else { return nil }
            return min(max(totalUsage / totalCredits, 0), 1)
        }
    }

    private struct CreditsResponse: Decodable {
        struct Payload: Decodable {
            let total_credits: Double
            let total_usage: Double
        }
        let data: Payload
    }

    /// Returns true when an OpenRouter key exists (env or credential store).
    /// Used to decide whether to show the section at all.
    public static func hasKey(agentDB: URL? = nil) -> Bool {
        apiKey(agentDB: agentDB) != nil
    }

    /// Best-effort load: nil when no key exists or the API call fails.
    /// Never throws — credits must not block the menu bar.
    /// Must not be called on the main thread (blocking network + sqlite).
    public static func loadFromOmp(
        agentDB: URL? = nil,
        timeoutSeconds: TimeInterval = 15
    ) -> Credits? {
        guard let key = apiKey(agentDB: agentDB) else { return nil }
        return try? fetchSync(apiKey: key, timeoutSeconds: timeoutSeconds)
    }

    public static func apiKey(agentDB: URL? = nil) -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"],
           !env.isEmpty
        {
            return env
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = (agentDB ?? home.appendingPathComponent(".omp/agent/agent.db")).path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db
        else {
            return nil
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT data FROM auth_credentials WHERE provider = 'openrouter' LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              let stmt
        else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let text = sqlite3_column_text(stmt, 0)
        else {
            return nil
        }
        let json = String(cString: text)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["key"] as? String,
              !key.isEmpty
        else {
            return nil
        }
        return key
    }

    public static func fetchSync(apiKey: String, timeoutSeconds: TimeInterval = 15) throws -> Credits {
        let url = URL(string: "https://openrouter.ai/api/v1/credits")!
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var result: Result<Credits, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
                return
            }
            guard let data,
                  let decoded = try? JSONDecoder().decode(CreditsResponse.self, from: data)
            else {
                result = .failure(CocoaError(.coderReadCorrupt))
                return
            }
            result = .success(Credits(
                totalCredits: decoded.data.total_credits,
                totalUsage: decoded.data.total_usage
            ))
        }.resume()
        semaphore.wait()
        return try result?.get() ?? { throw CocoaError(.coderReadCorrupt) }()
    }
}
