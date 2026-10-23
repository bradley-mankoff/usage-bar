import Foundation

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

    /// `OPENROUTER_API_KEY`, then the `openrouter` entry in pi's auth.json.
    static func apiKey() -> String? {
        Credentials.env("OPENROUTER_API_KEY") ?? Credentials.piApiKey(provider: "openrouter")
    }
}
