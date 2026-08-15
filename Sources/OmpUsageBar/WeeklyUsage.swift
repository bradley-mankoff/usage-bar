import Foundation
import SQLite3

/// Rolling-window consumption derived from a monotonic counter.
///
/// xAI's unified-billing accounts expose only a monthly included quota; the
/// weekly credits shape (`creditUsagePercent`) is omitted from the billing API
/// for those accounts. The widget therefore derives a rolling 7-day usage
/// number from the monthly `used` counter, which accumulates monotonically
/// until the monthly reset. omp's `usage_history` table (hourly `used_fraction`
/// snapshots) backfills the window so the number is correct from the first run.

struct XaiSample: Codable {
    let ts: Int64   // epoch milliseconds
    let used: Double
}

enum WeeklyUsage {
    static let windowSeconds: TimeInterval = 7 * 86400
    private static let pruneSeconds: TimeInterval = 8 * 86400

    /// Rolling `windowSeconds` consumption ending at `now`.
    /// Returns nil when no sample old enough exists to anchor the window.
    static func consumption(samples: [XaiSample], now: Date, window: TimeInterval = windowSeconds) -> Double? {
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - Int64(window * 1000)
        // Anchor on the last sample at or before the cutoff. A sample newer
        // than the cutoff means the window cannot be fully measured.
        guard let base = samples.last(where: { $0.ts <= cutoff }) else { return nil }

        var total = 0.0
        var prev = base.used
        for sample in samples where sample.ts > base.ts {
            if sample.used >= prev {
                total += sample.used - prev
            } else {
                // Counter reset (monthly rollover): usage since the reset is
                // measured from ~0, so the post-reset value is the increment.
                total += sample.used
            }
            prev = sample.used
        }
        return total
    }

    static func loadSamples() -> [XaiSample] {
        guard let data = try? Data(contentsOf: samplesPath()) else { return [] }
        return (try? JSONDecoder().decode([XaiSample].self, from: data)) ?? []
    }

    static func saveSamples(_ samples: [XaiSample]) {
        let dir = samplesPath().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(samples) {
            try? data.write(to: samplesPath())
        }
    }

    static func mergeAndPrune(_ samples: [XaiSample], now: Date = Date()) -> [XaiSample] {
        var byTs: [Int64: XaiSample] = [:]
        for sample in samples { byTs[sample.ts] = sample }
        let cutoff = Int64(now.timeIntervalSince1970 * 1000) - Int64(pruneSeconds * 1000)
        let pruned = byTs.values.filter { $0.ts >= cutoff }
        return pruned.sorted { $0.ts < $1.ts }
    }

    /// Seed the sample log from omp's hourly usage-history snapshots.
    /// Reads only `usage_history` (no credentials) via a read-only SQLite
    /// connection; returns [] when the table is missing or unreadable.
    static func backfillFromOmpHistory(monthlyLimit: Double) -> [XaiSample] {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".omp/agent/agent.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT recorded_at, used_fraction FROM usage_history
        WHERE provider = 'xai-oauth' AND limit_id = 'xai-oauth:included:1mo'
        ORDER BY recorded_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var out: [XaiSample] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = sqlite3_column_int64(stmt, 0)
            let fraction = sqlite3_column_double(stmt, 1)
            out.append(XaiSample(ts: ts, used: fraction * monthlyLimit))
        }
        return out
    }

    private static func samplesPath() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmpUsageBar", isDirectory: true)
            .appendingPathComponent("xai_samples.json")
    }
}
