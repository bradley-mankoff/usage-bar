import Foundation

/// Mirrors the `omp usage --json` output shape.
/// All amounts are optional so the widget degrades gracefully if
/// a provider omits fields in a future omp version.

struct UsageSnapshot: Codable {
    let generatedAt: Int64
    let reports: [ProviderReport]
}

struct ProviderReport: Codable {
    let provider: String
    let fetchedAt: Int64?
    let limits: [LimitReport]
    let notes: [String]?
    let resetCredits: ResetCredits?
    let metadata: ReportMetadata?
}

struct ResetCredits: Codable {
    let availableCount: Int?
}

struct ReportMetadata: Codable {
    let planType: String?
    let email: String?
    let billingKind: String?
    let source: String?
    let orgName: String?
}

struct LimitReport: Codable {
    let id: String
    let label: String
    let window: WindowInfo?
    let amount: AmountInfo?
    let status: String?
}

struct WindowInfo: Codable {
    let id: String?
    let label: String?
    let durationMs: Int64?
    let resetsAt: Int64?
}

struct AmountInfo: Codable {
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let usedFraction: Double?
    let remainingFraction: Double?
    let unit: String?
}

/// Persisted alongside the last snapshot so other tools (and tests)
/// can read the widget's view of the world without spawning omp.
struct PersistedState: Codable {
    let updatedAt: Date
    let snapshot: UsageSnapshot
}

/// Local NerfTrack projection persisted next to the last `omp usage` snapshot.
struct PersistedNerfTrack: Codable {
    let estimatedWeeklyValueUsd: Double?
    let lastCalibratedUsd: Double?
    let observedCostUsd: Double?
    let weeklyUsedPercent: Double?
    let status: String
    let confidence: String
    let validObservationCount: Int
    let note: String
}

struct PersistedModelQuote: Codable {
    let provider: String
    let windowId: String
    let windowLabel: String
    let modelId: String
    let displayName: String
    let deliveredUsd: Double
    let catalogIncludedMonthlyUsd: Double?
    let catalogMultiplier: Double?
    let note: String
}
