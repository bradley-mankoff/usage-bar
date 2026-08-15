import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    /// Derived rolling 7-day xAI consumption (nil until a full window exists).
    @Published var xaiWeeklyUsed: Double?
    /// True when the xAI report already carries a native weekly window.
    @Published var xaiNativeWeekly: Bool = false

    private var timer: Timer?
    private let refreshInterval: TimeInterval = 300 // aligns with omp's ~5 min usage cache
    private var samples: [XaiSample] = []
    private var didBackfill = false

    init() {
        samples = WeeklyUsage.loadSamples()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// Menu-bar label: the binding constraint (highest used fraction) across all providers.
    var barLabel: String {
        if let snapshot {
            let pct = Self.maxUsedPercent(snapshot) * 100
            let text = pct < 10 ? String(format: "%.1f%%", pct) : String(format: "%.0f%%", pct)
            return "\u{25C9} \(text)"
        }
        return errorMessage == nil ? "\u{25C9} \u{2026}" : "\u{25C9} ?"
    }

    func refresh() {
        Task {
            do {
                let snap = try await Task.detached(priority: .utility) {
                    try UsageFetcher.fetchSync()
                }.value
                snapshot = snap
                lastUpdated = Date()
                errorMessage = nil
                persist(snap)
                updateXaiDerived(snap)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    static func maxUsedPercent(_ snapshot: UsageSnapshot) -> Double {
        snapshot.reports.flatMap { $0.limits }
            .compactMap { $0.amount?.usedFraction }
            .max() ?? 0
    }

    /// Record the xAI monthly counter, backfill from omp history once, and
    /// compute the rolling 7-day consumption.
    private func updateXaiDerived(_ snap: UsageSnapshot) {
        guard let xai = snap.reports.first(where: { $0.provider == "xai-oauth" }),
              let monthly = xai.limits.first(where: { $0.id.contains(":included:1mo") }),
              let used = monthly.amount?.used,
              let limit = monthly.amount?.limit, limit > 0
        else {
            xaiWeeklyUsed = nil
            xaiNativeWeekly = false
            return
        }

        xaiNativeWeekly = xai.limits.contains { $0.id.contains(":1w") || $0.window?.id == "1w" }

        let now = Date()
        samples.append(XaiSample(ts: Int64(now.timeIntervalSince1970 * 1000), used: used))
        if !didBackfill {
            didBackfill = true
            let history = WeeklyUsage.backfillFromOmpHistory(monthlyLimit: limit)
            if !history.isEmpty {
                samples.append(contentsOf: history)
            }
        }
        samples = WeeklyUsage.mergeAndPrune(samples, now: now)
        WeeklyUsage.saveSamples(samples)
        xaiWeeklyUsed = WeeklyUsage.consumption(samples: samples, now: now)
    }

    private func persist(_ snapshot: UsageSnapshot) {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmpUsageBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let state = PersistedState(updatedAt: Date(), snapshot: snapshot)
        if let data = try? encoder.encode(state) {
            try? data.write(to: dir.appendingPathComponent("state.json"))
        }
    }
}
