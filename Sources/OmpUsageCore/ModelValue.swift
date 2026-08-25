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
        let specs: [(provider: String, limitId: String, label: String)] = [
            ("openai-codex", "openai-codex:primary", "week"),
            ("opencode-go", "weekly", "week"),
            ("opencode-go", "monthly", "month"),
        ]
        return specs.compactMap { spec in
            let observations = loadObservations(path: agent, provider: spec.provider, limitId: spec.limitId)
            let events = loadEvents(path: stats, provider: spec.provider)
            guard !observations.isEmpty, !events.isEmpty else { return nil }
            let quotes = estimate(
                provider: spec.provider,
                windowId: spec.limitId,
                observations: observations,
                events: events
            )
            guard !quotes.isEmpty else { return nil }
            return Bundle(
                provider: spec.provider,
                windowId: spec.limitId,
                windowLabel: spec.label,
                models: quotes
            )
        }
    }

    public static func estimate(
        provider: String,
        windowId: String,
        observations: [NerfTrack.Observation],
        events: [TokenEvent]
    ) -> [ModelQuote] {
        let reprice = provider == "opencode-go"
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
            if reprice, let priced = listPrice(event) {
                cost = priced
            } else {
                cost = event.costUsd
            }
            guard cost.isFinite, cost > 0 else { continue }
            byModel[id, default: 0] += cost
        }
        return byModel.keys.sorted().compactMap { modelId in
            let delivered = byModel[modelId] ?? 0
            guard delivered > 0 else { return nil }
            let catalog = provider == "opencode-go" ? GoCatalog.lookup(modelId) : nil
            return ModelQuote(
                provider: provider,
                windowId: windowId,
                modelId: modelId,
                displayName: catalog?.displayName ?? modelId,
                deliveredUsd: delivered,
                catalogIncludedMonthlyUsd: catalog?.includedMonthlyUsd,
                catalogMultiplier: catalog?.multiplier,
                listPriced: reprice && catalog != nil,
                note: annotate(delivered: delivered, catalog: catalog, reprice: reprice)
            )
        }
        .sorted { $0.deliveredUsd > $1.deliveredUsd }
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
