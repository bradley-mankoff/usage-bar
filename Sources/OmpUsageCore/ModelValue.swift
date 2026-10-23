import Foundation
import SQLite3

/// Per-model delivered list cost inside a shared subscription window.
///
/// Do not pair a model's tokens with the shared pool percent. That formula
/// (`cost / (percent/100)`) is only valid for the whole-pool quote. A cheap
/// model that moves 1% of a $60 pool at list $1.37 is $137/wk of fiction.
/// The per-model headline is the list-priced dollars actually delivered
/// in the current window. Catalog $15/$30/$60 is advertised, shown as ×.
public enum ModelValue {
    public struct TokenEvent: Equatable, Sendable {
        public var timestampMs: Int64
        public var model: String
        public var costUsd: Double
        public var inputTokens: Double
        public var outputTokens: Double
        public var cacheReadTokens: Double
        public var cacheWriteTokens: Double

        public init(
            timestampMs: Int64,
            model: String,
            costUsd: Double,
            inputTokens: Double = 0,
            outputTokens: Double = 0,
            cacheReadTokens: Double = 0,
            cacheWriteTokens: Double = 0
        ) {
            self.timestampMs = timestampMs
            self.model = model
            self.costUsd = costUsd
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
        }
    }

    public struct ModelQuote: Equatable, Sendable, Identifiable {
        public var id: String { "\(provider)|\(windowId)|\(modelId)" }
        public var provider: String
        public var windowId: String
        public var modelId: String
        public var displayName: String
        public var deliveredUsd: Double
        public var catalogIncludedMonthlyUsd: Double?
        public var catalogMultiplier: Double?
        public var listPriced: Bool
        public var note: String
    }

    public struct Bundle: Equatable, Sendable, Identifiable {
        public var id: String { "\(provider)|\(windowId)" }
        public var provider: String
        public var windowId: String
        public var windowLabel: String
        public var models: [ModelQuote]
    }

    public static func loadFromOmp(
        agentDB: URL? = nil,
        statsDB: URL? = nil
    ) -> [Bundle] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let agent = (agentDB ?? home.appendingPathComponent(".omp/agent/agent.db")).path
        let stats = (statsDB ?? home.appendingPathComponent(".omp/stats.db")).path
        let specs: [(provider: String, limitId: String, windowId: String, label: String)] = [
            ("openai-codex", "openai-codex:primary", "openai-codex:primary", "week"),
            ("xai-oauth", "xai-oauth:credits:1w", "xai-oauth:credits:1w", "week"),
            ("opencode-go", "weekly", "weekly", "week"),
            ("opencode-go", "monthly", "monthly", "month"),
        ]
        var bundles: [Bundle] = specs.compactMap { spec in
            let observations = loadObservations(path: agent, provider: spec.provider, limitId: spec.limitId)
            let events = loadEvents(path: stats, provider: spec.provider)
            guard !observations.isEmpty, !events.isEmpty else { return nil }
            let quotes = estimate(
                provider: spec.provider,
                windowId: spec.windowId,
                observations: observations,
                events: events
            )
            guard !quotes.isEmpty else { return nil }
            return Bundle(
                provider: spec.provider,
                windowId: spec.windowId,
                windowLabel: spec.label,
                models: quotes
            )
        }
        // xAI note: usage_history for xai-oauth:credits:1w never regresses
        // (0 -> 100% monotonic across resets), so windowGroups yields one
        // giant window and estimate() prices all 1517 token rows since 08-03
        // against the current cycle.
        if !bundles.contains(where: { $0.provider == "xai-oauth" }),
           let prev = xaiLatestPricedCycleBundle(agentPath: agent, statsPath: stats) {
            bundles.append(prev)
        }
        return bundles
    }

    /// Reprice xAI tokens from the most recent cycle that has any priced
    /// token events. omp stopped writing xai-oauth rows after 09-10, so the
    /// current cycle is empty; walking back to the latest priced cycle keeps
    /// the row showing a real measured value. Nil when no cycle prices.
    static func xaiLatestPricedCycleBundle(agentPath: String, statsPath: String) -> Bundle? {
        let resets = loadResetBoundaries(path: agentPath, provider: "xai-oauth", limitId: "xai-oauth:credits:1w")
        guard !resets.isEmpty else { return nil }
        let events = loadEvents(path: statsPath, provider: "xai-oauth")
        guard !events.isEmpty else { return nil }
        let bounds: [Int64] = [0] + resets
        for i in (1..<bounds.count).reversed() {
            let start = bounds[i - 1]
            let end = bounds[i]
            // Cycle windows are (prevReset, reset]: usage_history rows carry
            // the upcoming reset, so events land in the first window whose
            // end is at/after the event. Using strict > on the event side
            // matches estimate()'s (startMs, endMs] convention.
            let inCycle = events.filter { $0.timestampMs > start && $0.timestampMs <= end }
            guard !inCycle.isEmpty else { continue }
            var byModel: [String: Double] = [:]
            for event in inCycle {
                let cost = xaiListPrice(event)
                guard cost.isFinite, cost > 0 else { continue }
                byModel[GoCatalog.normalize(event.model), default: 0] += cost
            }
            let quotes = byModel.keys.sorted().compactMap { modelId -> ModelQuote? in
                let delivered = byModel[modelId] ?? 0
                guard delivered > 0 else { return nil }
                return ModelQuote(
                    provider: "xai-oauth",
                    windowId: "xai-oauth:credits:1w",
                    modelId: modelId,
                    displayName: displayNameFor(provider: "xai-oauth", modelId: modelId),
                    deliveredUsd: delivered,
                    catalogIncludedMonthlyUsd: nil,
                    catalogMultiplier: nil,
                    listPriced: true,
                    note: "latest priced cycle · list-priced Grok API tokens"
                )
            }.sorted { $0.deliveredUsd > $1.deliveredUsd }
            guard !quotes.isEmpty else { continue }
            return Bundle(
                provider: "xai-oauth",
                windowId: "xai-oauth:credits:1w",
                windowLabel: "week",
                models: quotes
            )
        }
        return nil
    }

    /// Distinct cycle-end boundaries from usage_history resets, ascending.
    static func loadResetBoundaries(path: String, provider: String, limitId: String) -> [Int64] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT DISTINCT resets_at FROM usage_history
        WHERE provider = ?1 AND limit_id = ?2 AND resets_at IS NOT NULL
        ORDER BY resets_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, limitId, -1, SQLITE_TRANSIENT)
        var out: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(sqlite3_column_int64(stmt, 0))
        }
        return out
    }

    public static func estimate(
        provider: String,
        windowId: String,
        observations: [NerfTrack.Observation],
        events: [TokenEvent]
    ) -> [ModelQuote] {
        let windows = NerfTrack.windowGroups(NerfTrack.dedupedObservations(observations))
        guard let current = windows.last, let endMs = current.points.last?.timestampMs else {
            return []
        }
        let startMs = current.startedAtMs
        var byModel: [String: Double] = [:]
        for event in events {
            guard event.timestampMs > startMs, event.timestampMs <= endMs else { continue }
            let id = GoCatalog.normalize(event.model)
            let cost: Double
            switch provider {
            case "opencode-go":
                guard let priced = listPrice(event) else { continue }
                cost = priced
            case "xai-oauth":
                cost = xaiListPrice(event)
            default:
                cost = event.costUsd
            }
            guard cost.isFinite, cost > 0 else { continue }
            byModel[id, default: 0] += cost
        }
        return byModel.keys.sorted().compactMap { modelId in
            let delivered = byModel[modelId] ?? 0
            guard delivered > 0 else { return nil }
            let catalog = provider == "opencode-go" ? GoCatalog.lookup(modelId) : nil
            let repriced: Bool
            let note: String
            switch provider {
            case "opencode-go":
                repriced = catalog != nil
                note = annotate(delivered: delivered, catalog: catalog, reprice: true)
            case "xai-oauth":
                repriced = true
                note = "delivered this window · list-priced Grok API tokens"
            default:
                repriced = false
                note = annotate(delivered: delivered, catalog: nil, reprice: false)
            }
            return ModelQuote(
                provider: provider,
                windowId: windowId,
                modelId: modelId,
                displayName: displayNameFor(provider: provider, modelId: modelId),
                deliveredUsd: delivered,
                catalogIncludedMonthlyUsd: catalog?.includedMonthlyUsd,
                catalogMultiplier: catalog?.multiplier,
                listPriced: repriced,
                note: note
            )
        }
        .sorted { $0.deliveredUsd > $1.deliveredUsd }
    }

    static func displayNameFor(provider: String, modelId: String) -> String {
        if provider == "xai-oauth" { return GoCatalog.xaiLookup(modelId).displayName }
        return GoCatalog.displayName(modelId)
    }

    /// List-price one xAI token event at current Grok API rates. Unknown
    /// models fall back to Grok 4.6 rates.
    static func xaiListPrice(_ event: TokenEvent) -> Double {
        let model = GoCatalog.xaiLookup(event.model)
        var usd = event.inputTokens * model.inputPerM / 1_000_000
            + event.outputTokens * model.outputPerM / 1_000_000
            + event.cacheReadTokens * model.cachedReadPerM / 1_000_000
        if let write = model.cachedWritePerM {
            usd += event.cacheWriteTokens * write / 1_000_000
        }
        return usd
    }

    public static func displayAmount(_ item: ModelQuote) -> Double {
        item.deliveredUsd
    }

    static func annotate(
        delivered: Double,
        catalog: GoCatalog.Model?,
        reprice: Bool
    ) -> String {
        var parts: [String] = []
        parts.append("delivered this window")
        if let catalog {
            let x = catalog.multiplier == catalog.multiplier.rounded()
                ? String(format: "%.0f", catalog.multiplier)
                : String(format: "%.1f", catalog.multiplier)
            parts.append("catalog $\(Int(catalog.includedMonthlyUsd))/mo · \(x)×")
        }
        if reprice {
            parts.append("list-priced tokens")
        }
        _ = delivered
        return parts.joined(separator: " · ")
    }
    static func listPrice(_ event: TokenEvent) -> Double? {
        guard let model = GoCatalog.lookup(event.model) else { return nil }
        // omp `messages` stores uncached input separately from cache_read.
        var usd = event.inputTokens * model.inputPerM / 1_000_000
            + event.outputTokens * model.outputPerM / 1_000_000
            + event.cacheReadTokens * model.cachedReadPerM / 1_000_000
        if let write = model.cachedWritePerM {
            usd += event.cacheWriteTokens * write / 1_000_000
        }
        return usd.isFinite && usd > 0 ? usd : nil
    }

    static func loadObservations(path: String, provider: String, limitId: String) -> [NerfTrack.Observation] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT recorded_at, used_fraction, resets_at FROM usage_history
        WHERE provider = ?1 AND limit_id = ?2
        ORDER BY recorded_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, limitId, -1, SQLITE_TRANSIENT)
        var out: [NerfTrack.Observation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_int64(stmt, 0)
            let fraction = sqlite3_column_double(stmt, 1)
            let reset: Int64? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                ? nil
                : sqlite3_column_int64(stmt, 2)
            out.append(NerfTrack.Observation(timestampMs: ts, usedPercent: fraction * 100, resetAtMs: reset))
        }
        return out
    }

    static func loadEvents(path: String, provider: String) -> [TokenEvent] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return []
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT timestamp, model, cost_total, input_tokens, output_tokens,
               cache_read_tokens, cache_write_tokens
        FROM messages
        WHERE provider = ?1 AND model IS NOT NULL
        ORDER BY timestamp
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider, -1, SQLITE_TRANSIENT)
        var out: [TokenEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            guard !model.isEmpty else { continue }
            out.append(TokenEvent(
                timestampMs: sqlite3_column_int64(stmt, 0),
                model: model,
                costUsd: sqlite3_column_double(stmt, 2),
                inputTokens: sqlite3_column_double(stmt, 3),
                outputTokens: sqlite3_column_double(stmt, 4),
                cacheReadTokens: sqlite3_column_double(stmt, 5),
                cacheWriteTokens: sqlite3_column_double(stmt, 6)
            ))
        }
        return out
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
