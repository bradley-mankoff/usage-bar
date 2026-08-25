import Foundation
import SwiftUI
import OmpUsageCore

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    /// Derived rolling 7-day xAI consumption (nil until a full window exists).
    @Published var xaiWeeklyUsed: Double?
    /// True when the xAI report already carries a native weekly window.
    @Published var xaiNativeWeekly: Bool = false
    /// Local NerfTrack weekly API-equivalent quote (never blocks the bar).
    @Published var nerfTrack: NerfTrack.Quote?
    /// Per-model pairings against each shared subscription meter.
    @Published var modelValues: [ModelValue.Bundle] = []
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
            let quoteTask = Task.detached(priority: .utility) {
                (NerfTrack.loadFromOmp(), ModelValue.loadFromOmp())
            }
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
            let (quote, models) = await quoteTask.value
            nerfTrack = quote
            modelValues = models
            persistNerfTrack(quote)
            persistModelValues(models)
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

    private func persistNerfTrack(_ quote: NerfTrack.Quote) {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmpUsageBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let state = PersistedNerfTrack(
            estimatedWeeklyValueUsd: quote.estimatedWeeklyValueUsd,
            lastCalibratedUsd: quote.lastCalibratedUsd,
            observedCostUsd: quote.observedCostUsd,
            weeklyUsedPercent: quote.weeklyUsedPercent,
            status: quote.status.rawValue,
            confidence: quote.confidence.rawValue,
            validObservationCount: quote.validObservationCount,
            note: quote.note
        )
        if let data = try? encoder.encode(state) {
            try? data.write(to: dir.appendingPathComponent("nerftrack.json"))
        }
    }


    func bundles(for provider: String) -> [ModelValue.Bundle] {
        modelValues.filter { $0.provider == provider }
    }

    private func persistModelValues(_ bundles: [ModelValue.Bundle]) {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmpUsageBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let rows: [PersistedModelQuote] = bundles.flatMap { bundle in
            bundle.models.map { item in
                PersistedModelQuote(
                    provider: item.provider,
                    windowId: item.windowId,
                    windowLabel: bundle.windowLabel,
                    modelId: item.modelId,
                    displayName: item.displayName,
                    deliveredUsd: item.deliveredUsd,
                    catalogIncludedMonthlyUsd: item.catalogIncludedMonthlyUsd,
                    catalogMultiplier: item.catalogMultiplier,
                    note: item.note
                )
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(rows) {
            try? data.write(to: dir.appendingPathComponent("model-value.json"))
        }
    }
}
