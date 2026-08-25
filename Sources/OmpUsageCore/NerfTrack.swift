import Foundation
import SQLite3

/// NerfTrack's published weekly API-equivalent estimator, run locally against
/// omp's already-priced Codex token rows and weekly quota snapshots.
///
/// Formula (https://github.com/Ayaan-Lashari/NerfTrack/blob/main/docs/CALCULATION.md):
/// `estimated_weekly_usd = cost_delta / (percent_delta / 100)`
/// Headline is the median of the latest seven valid *cumulative* estimates.
/// Zero/negative movement is pending, not a fabricated zero.
public enum NerfTrack {
    public static let algorithmVersion = "nerftrack-token-api-equivalent-v5"
    public static let medianSampleCount = 7
    public static let materialDecreasePercent = 0.01
    public static let resetJitterMs: Int64 = 5 * 60 * 1_000

    public struct Observation: Equatable, Sendable {
        public let timestampMs: Int64
        public let usedPercent: Double
        public let resetAtMs: Int64?

        public init(timestampMs: Int64, usedPercent: Double, resetAtMs: Int64?) {
            self.timestampMs = timestampMs
            self.usedPercent = usedPercent
            self.resetAtMs = resetAtMs
        }
    }

    public struct CostEvent: Equatable, Sendable {
        public let timestampMs: Int64
        public let costUsd: Double

        public init(timestampMs: Int64, costUsd: Double) {
            self.timestampMs = timestampMs
            self.costUsd = costUsd
        }
    }

    public enum Status: String, Equatable, Sendable {
        case valid
        case pending
        case empty
    }

    public enum Confidence: String, Equatable, Sendable {
        case high
        case medium
        case low
        case none
    }

    public struct Quote: Equatable, Sendable {
        public var estimatedWeeklyValueUsd: Double?
        public var lastCalibratedUsd: Double?
        public var observedCostUsd: Double?
        public var weeklyUsedPercent: Double?
        public var resetAtMs: Int64?
        public var status: Status
        public var confidence: Confidence
        public var validObservationCount: Int
        public var percentageCoverage: Double?
        public var note: String
    }

    public enum Decision: Equatable, Sendable {
        case valid(costDeltaUsd: Double, percentDelta: Double, estimatedWeeklyValueUsd: Double)
        case pending
        case rejected
    }

    public static func measureInterval(
        previousCostUsd: Double,
        currentCostUsd: Double,
        previousUsedPercent: Double,
        currentUsedPercent: Double
    ) -> Decision {
        let values = [previousCostUsd, currentCostUsd, previousUsedPercent, currentUsedPercent]
        if values.contains(where: { !$0.isFinite }) { return .rejected }
        let costDelta = currentCostUsd - previousCostUsd
        let percentDelta = currentUsedPercent - previousUsedPercent
        if percentDelta < -materialDecreasePercent { return .rejected }
        if costDelta <= 0 || percentDelta <= 0 { return .pending }
        let estimate = costDelta / (percentDelta / 100)
        if !estimate.isFinite || estimate <= 0 { return .rejected }
        return .valid(
            costDeltaUsd: costDelta,
            percentDelta: percentDelta,
            estimatedWeeklyValueUsd: estimate
        )
    }

    public static func medianRecent(_ values: [Double], sampleCount: Int = medianSampleCount) -> Double? {
        var recent = Array(
            values.reversed().filter { $0.isFinite && $0 > 0 }.prefix(max(sampleCount, 1))
        )
        if recent.isEmpty { return nil }
        recent.sort(by: <)
        return recent[recent.count / 2]
    }

    public static func relativeMedianDeviation(
        _ values: [Double],
        sampleCount: Int = medianSampleCount
    ) -> Double? {
        guard let median = medianRecent(values, sampleCount: sampleCount) else { return nil }
        var deviations = Array(
            values.reversed()
                .filter { $0.isFinite && $0 > 0 }
                .prefix(max(sampleCount, 1))
                .map { abs($0 - median) }
        )
        if deviations.isEmpty { return nil }
        deviations.sort(by: <)
        return deviations[deviations.count / 2] / median
    }

    public static func confidence(
        validObservationCount: Int,
        percentageCoverage: Double,
        relativeDeviation: Double
    ) -> Confidence {
        if validObservationCount >= 5 && percentageCoverage >= 20 && relativeDeviation <= 0.10 {
            return .high
        }
        if validObservationCount >= 2 && percentageCoverage >= 5 && relativeDeviation <= 0.25 {
            return .medium
        }
        if validObservationCount >= 1 { return .low }
        return .none
    }

    public static func estimate(observations: [Observation], costs: [CostEvent]) -> Quote {
        let observations = dedupedObservations(observations)
        guard let latest = observations.last else {
            return Quote(
                estimatedWeeklyValueUsd: nil,
                lastCalibratedUsd: nil,
                observedCostUsd: nil,
                weeklyUsedPercent: nil,
                resetAtMs: nil,
                status: .empty,
                confidence: .none,
                validObservationCount: 0,
                percentageCoverage: nil,
                note: "No Codex weekly snapshots yet."
            )
        }

        let windows = windowGroups(observations)
        let prefix = costPrefix(costs)
        var lastCalibrated: Double?
        var current: (
            estimate: Double?,
            cost: Double,
            coverage: Double?,
            count: Int,
            confidence: Confidence
        )?

        for window in windows {
            let rebuilt = rebuild(window: window, prefix: prefix)
            if let median = rebuilt.median {
                lastCalibrated = median
            }
            current = (
                estimate: rebuilt.median,
                cost: rebuilt.observedCost,
                coverage: rebuilt.coverage,
                count: rebuilt.count,
                confidence: rebuilt.confidence
            )
        }

        let currentEstimate = current?.estimate
        let status: Status = currentEstimate == nil ? .pending : .valid
        let note: String
        if currentEstimate != nil {
            note = "Rolling median of cumulative weekly cost-per-percent estimates."
        } else if lastCalibrated != nil {
            note = "Current week has no paired token-cost movement yet; showing last calibrated window."
        } else {
            note = "Waiting for a positive weekly-usage change paired with local token cost."
        }

        return Quote(
            estimatedWeeklyValueUsd: currentEstimate,
            lastCalibratedUsd: lastCalibrated,
            observedCostUsd: current?.cost,
            weeklyUsedPercent: latest.usedPercent,
            resetAtMs: latest.resetAtMs,
            status: status,
            confidence: current?.confidence ?? .none,
            validObservationCount: current?.count ?? 0,
            percentageCoverage: current?.coverage,
            note: note
        )
    }

    public static func loadFromOmp(
        agentDB: URL? = nil,
        statsDB: URL? = nil
    ) -> Quote {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let agent = agentDB ?? home.appendingPathComponent(".omp/agent/agent.db")
        let stats = statsDB ?? home.appendingPathComponent(".omp/stats.db")
        let observations = loadObservations(path: agent.path)
        let costs = loadCosts(path: stats.path)
        return estimate(observations: observations, costs: costs)
    }

    // MARK: - Windows

    struct Window {
        var resetAtMs: Int64?
        var startedAtMs: Int64
        var points: [Observation]
    }

    static func windowGroups(_ observations: [Observation]) -> [Window] {
        var groups: [Window] = []
        for current in observations {
            let newReason: String? = {
                guard let previous = groups.last?.points.last else { return nil }
                let usageRegressed = current.usedPercent < previous.usedPercent - materialDecreasePercent
                guard usageRegressed else { return nil }
                let groupReset = groups.last?.resetAtMs
                let resetChanged: Bool
                switch (groupReset, current.resetAtMs) {
                case let (prev?, next?):
                    resetChanged = abs(prev - next) > resetJitterMs
                case (nil, nil):
                    resetChanged = false
                default:
                    resetChanged = true
                }
                if resetChanged { return "reported_reset_changed" }
                if let reset = groupReset, current.timestampMs >= reset - resetJitterMs {
                    return "scheduled_reset"
                }
                return nil
            }()

            if newReason != nil {
                groups.append(Window(
                    resetAtMs: current.resetAtMs,
                    startedAtMs: current.timestampMs,
                    points: [current]
                ))
            } else if var last = groups.last {
                if current.usedPercent < last.points[last.points.count - 1].usedPercent - materialDecreasePercent {
                    continue
                }
                last.points.append(current)
                groups[groups.count - 1] = last
            } else {
                groups.append(Window(
                    resetAtMs: current.resetAtMs,
                    startedAtMs: current.timestampMs,
                    points: [current]
                ))
            }
        }
        return groups
    }

    static func dedupedObservations(_ observations: [Observation]) -> [Observation] {
        var best: [Int64: Observation] = [:]
        var order: [Int64] = []
        for item in observations {
            guard item.usedPercent.isFinite, item.usedPercent >= 0, item.usedPercent <= 100 else {
                continue
            }
            let key = item.timestampMs / 1000
            if best[key] == nil { order.append(key) }
            if let existing = best[key] {
                if item.timestampMs > existing.timestampMs
                    || (item.timestampMs == existing.timestampMs && item.usedPercent >= existing.usedPercent)
                {
                    best[key] = item
                }
            } else {
                best[key] = item
            }
        }
        return order.compactMap { best[$0] }
    }

    // MARK: - Rebuild

    struct Rebuilt {
        var median: Double?
        var observedCost: Double
        var coverage: Double?
        var count: Int
        var confidence: Confidence
    }

    static func rebuild(window: Window, prefix: [(Int64, Double)]) -> Rebuilt {
        guard let first = window.points.first else {
            return Rebuilt(median: nil, observedCost: 0, coverage: nil, count: 0, confidence: .none)
        }
        let baseline = costThrough(prefix, startMs: window.startedAtMs, endMs: first.timestampMs)
        var previous = first
        var previousCost = baseline
        var rates: [Double] = []
        var lastCost = baseline
        for current in window.points.dropFirst() {
            let currentCost = costThrough(prefix, startMs: window.startedAtMs, endMs: current.timestampMs)
            lastCost = currentCost
            switch measureInterval(
                previousCostUsd: previousCost,
                currentCostUsd: currentCost,
                previousUsedPercent: previous.usedPercent,
                currentUsedPercent: current.usedPercent
            ) {
            case .valid:
                let cumulative: Double
                if case let .valid(_, _, estimate) = measureInterval(
                    previousCostUsd: baseline,
                    currentCostUsd: currentCost,
                    previousUsedPercent: first.usedPercent,
                    currentUsedPercent: current.usedPercent
                ) {
                    cumulative = estimate
                } else if case let .valid(_, _, estimate) = measureInterval(
                    previousCostUsd: previousCost,
                    currentCostUsd: currentCost,
                    previousUsedPercent: previous.usedPercent,
                    currentUsedPercent: current.usedPercent
                ) {
                    cumulative = estimate
                } else {
                    previous = current
                    previousCost = currentCost
                    continue
                }
                rates.append(cumulative)
            case .pending, .rejected:
                break
            }
            previous = current
            previousCost = currentCost
        }
        let coverage = max(0, (window.points.last?.usedPercent ?? first.usedPercent) - first.usedPercent)
        let deviation = relativeMedianDeviation(rates) ?? .infinity
        return Rebuilt(
            median: medianRecent(rates),
            observedCost: lastCost,
            coverage: rates.isEmpty ? nil : coverage,
            count: rates.count,
            confidence: confidence(
                validObservationCount: rates.count,
                percentageCoverage: coverage,
                relativeDeviation: deviation
            )
        )
    }

    static func costPrefix(_ costs: [CostEvent]) -> [(Int64, Double)] {
        var acc = 0.0
        var out: [(Int64, Double)] = []
        for event in costs.sorted(by: { $0.timestampMs < $1.timestampMs }) {
            guard event.costUsd.isFinite else { continue }
            acc += max(event.costUsd, 0)
            out.append((event.timestampMs, acc))
        }
        return out
    }

    /// Inclusive of `endMs`, exclusive of `startMs` — same bound as NerfTrack `cost_through`.
    static func costThrough(_ prefix: [(Int64, Double)], startMs: Int64, endMs: Int64) -> Double {
        func upto(_ t: Int64) -> Double {
            var lo = 0
            var hi = prefix.count - 1
            var ans = 0.0
            while lo <= hi {
                let mid = (lo + hi) / 2
                if prefix[mid].0 <= t {
                    ans = prefix[mid].1
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            return ans
        }
        let value = upto(endMs) - upto(startMs)
        return value.isFinite ? max(value, 0) : 0
    }

    // MARK: - omp SQLite

    static func loadObservations(path: String) -> [Observation] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT recorded_at, used_fraction, resets_at FROM usage_history
        WHERE provider = 'openai-codex'
        ORDER BY recorded_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Observation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_int64(stmt, 0)
            let fraction = sqlite3_column_double(stmt, 1)
            let reset: Int64? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(stmt, 2)
            out.append(Observation(timestampMs: ts, usedPercent: fraction * 100, resetAtMs: reset))
        }
        return out
    }

    static func loadCosts(path: String) -> [CostEvent] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT timestamp, cost_total FROM messages
        WHERE provider = 'openai-codex' AND cost_total IS NOT NULL
        ORDER BY timestamp
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [CostEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(CostEvent(
                timestampMs: sqlite3_column_int64(stmt, 0),
                costUsd: sqlite3_column_double(stmt, 1)
            ))
        }
        return out
    }
}
