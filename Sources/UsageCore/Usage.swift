import Foundation

/// One rate-limit window of a subscription, e.g. Claude's 5-hour window or
/// OpenCode Go's monthly window.
public struct UsageWindow: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var usedFraction: Double
    public var resetsAt: Date?
    public var isWeekly: Bool

    public init(id: String, label: String, usedFraction: Double, resetsAt: Date?, isWeekly: Bool) {
        self.id = id
        self.label = label
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
        self.isWeekly = isWeekly
    }
}

/// A banked reset that clears a subscription's limits when redeemed, e.g.
/// Codex's "Full reset (Weekly + 5 hr)". Unused ones expire.
public struct ResetCredit: Equatable, Sendable {
    public var title: String
    public var expiresAt: Date?

    public init(title: String, expiresAt: Date?) {
        self.title = title
        self.expiresAt = expiresAt
    }
}

/// A subscription's windows plus its API-equivalent monthly value, which
/// weights it in the menu-bar percent (see SubscriptionValue).
public struct SubscriptionUsage: Equatable, Sendable {
    public var name: String
    public var plan: String?
    public var monthlyValueUsd: Double
    public var windows: [UsageWindow]
    public var note: String?
    /// Available resets, soonest expiry first.
    public var resetCredits: [ResetCredit]

    public init(
        name: String, plan: String?, monthlyValueUsd: Double, windows: [UsageWindow],
        note: String? = nil, resetCredits: [ResetCredit] = []
    ) {
        self.name = name
        self.plan = plan
        self.monthlyValueUsd = monthlyValueUsd
        self.windows = windows
        self.note = note
        self.resetCredits = resetCredits
    }

    public var weeklyFraction: Double? {
        windows.filter(\.isWeekly).map(\.usedFraction).max()
    }
}

public enum UsageError: LocalizedError {
    case missingCredential(String)
    case http(Int, String)
    case reauth(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let what): return "No credential: \(what)"
        case .http(let status, let what): return "\(what) returned HTTP \(status)"
        case .reauth(let what): return "\(what) sign-in expired \u{2014} sign this seat in again"
        case .badResponse(let what): return "Could not read the \(what) response"
        }
    }
}

enum HTTP {
    static func get(_ url: String, headers: [String: String], what: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UsageError.http(status, what) }
        return data
    }
}

/// ISO 8601 with or without fractional seconds; Anthropic sends microseconds,
/// which ISO8601DateFormatter rejects, so the fraction is trimmed first.
func parseISODate(_ text: String?) -> Date? {
    guard let text else { return nil }
    let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: trimmed)
}
