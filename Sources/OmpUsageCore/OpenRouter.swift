import Foundation
import SQLite3

/// OpenRouter pay-as-you-go credits, in dollars.
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

    public static func fetch() async throws -> Credits {
        guard let key = apiKey() else {
            throw UsageError.missingCredential("no OpenRouter key (OPENROUTER_API_KEY or pi's auth.json)")
        }
        let body = try await HTTP.get("https://openrouter.ai/api/v1/credits", headers: [
            "Authorization": "Bearer \(key)",
        ], what: "OpenRouter credits")
        return try parse(body)
    }

    /// Response shape: `{"data": {"total_credits": 20, "total_usage": 3.37}}`.
    public static func parse(_ data: Data) throws -> Credits {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let total = (payload["total_credits"] as? NSNumber)?.doubleValue,
              let used = (payload["total_usage"] as? NSNumber)?.doubleValue
        else { throw UsageError.badResponse("OpenRouter credits") }
        return Credits(totalCredits: total, totalUsage: used)
    }

    /// `OPENROUTER_API_KEY`, then an `openrouter` entry in pi's auth.json,
    /// then omp's credential store. The omp fallback exists because, as of
    /// 2026-10-23, omp's database is the only place a working key lives;
    /// remove it once the key is in pi.
    static func apiKey() -> String? {
        Credentials.env("OPENROUTER_API_KEY")
            ?? Credentials.piApiKey(provider: "openrouter")
            ?? ompKey()
    }

    private static func ompKey() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omp/agent/agent.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT data FROM auth_credentials WHERE provider = 'openrouter' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0),
              let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8)) as? [String: Any],
              let key = obj["key"] as? String, !key.isEmpty
        else { return nil }
        return key
    }
}
