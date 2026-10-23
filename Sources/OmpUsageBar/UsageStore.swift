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
    /// OpenRouter pay-as-you-go credits (omp reports no usage for API keys).
    @Published var openRouter: OpenRouter.Credits?
    /// True when an OpenRouter key exists, even if the fetch hasn't succeeded.
    @Published var openRouterKeyFound = false
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

    /// Menu-bar label: API-equivalent dollar-weighted average of *weekly*
    /// usage across linked subscriptions (see SubscriptionValue). Weekly is
    /// the only window all three share, so 5h/monthly windows never skew the
    /// label. OpenRouter $ balance appends as text only, never into the %.
    /// No icon: the bar shows the number bare (e.g. `60% · $12.30`).
    /// Ended subscriptions are excluded so a canceled plan pinned at 100%
    /// can't wedge the label. Falls back to weekly max when nothing has a
    /// known dollar value.
    var barLabel: String {
        if let snapshot {
            let frac = Self.weightedWeeklyPercent(snapshot) ?? Self.maxWeeklyPercent(snapshot)
            let pct = frac * 100
            var text = pct < 10 ? String(format: "%.1f%%", pct) : String(format: "%.0f%%", pct)
            if let credits = openRouter, credits.totalCredits > 0 {
                text += String(format: " · $%.2f", credits.remaining)
            }
            return text
        }
        return errorMessage == nil ? "…" : "?"
    }

    /// Dollar-weighted average of each active provider's weekly window.
    /// Nil when no active provider has a known subscription value.
    static func weightedWeeklyPercent(_ snapshot: UsageSnapshot) -> Double? {
        let items: [(usedFraction: Double, valueUsd: Double)] = snapshot.reports
            .filter { !$0.isInactive }
            .compactMap { report in
                guard let value = SubscriptionValue.valueUsd(
                    provider: report.provider, planType: report.metadata?.planType
                ) else { return nil }
                guard let frac = SubscriptionValue.weeklyFraction(limits: report.limits.map {
                    ($0.window?.id, $0.id, $0.amount?.usedFraction)
                }) else { return nil }
                return (frac, value)
            }
        return SubscriptionValue.weightedFraction(items)
    }

    func refresh() {
        Task {
            let quoteTask = Task.detached(priority: .utility) {
                (NerfTrack.loadFromOmp(), ModelValue.loadFromOmp(), OpenRouter.loadFromOmp(), OpenRouter.hasKey())
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
            let (quote, models, credits, keyFound) = await quoteTask.value
            nerfTrack = quote
            modelValues = models
            openRouter = credits
            openRouterKeyFound = keyFound
            persistNerfTrack(quote)
            persistModelValues(models)
            if let credits { persistOpenRouter(credits) }
            #if DEBUG
            print("[OmpUsageBar] models=\(models.count) providers=\(Set(models.map { $0.provider }).sorted())")
            #endif
        }
    }

    /// Highest weekly used fraction across active providers only (fallback
    /// when no provider has a known dollar value). Inactive (ended)
    /// subscriptions are excluded: they sit at 100% exhausted on a
    /// downgraded free plan and would otherwise pin the bar.
    static func maxWeeklyPercent(_ snapshot: UsageSnapshot) -> Double {
        snapshot.reports.filter { !$0.isInactive }.compactMap {
            SubscriptionValue.weeklyFraction(limits: $0.limits.map {
                ($0.window?.id, $0.id, $0.amount?.usedFraction)
            })
        }.max() ?? 0
    }

    /// Highest used fraction across active providers only (legacy max-label).
    /// Kept for reference; the bar now uses the weekly windows above.
    /// Inactive (ended) subscriptions are excluded: they sit at 100%
    /// exhausted on a downgraded free plan and would otherwise pin the bar.
    static func maxUsedPercent(_ snapshot: UsageSnapshot) -> Double {
        snapshot.reports.filter { !$0.isInactive }.flatMap { $0.limits }
            .compactMap { $0.amount?.usedFraction }
            .max() ?? 0
    }

    /// xAI API value is computed from token rows (see ModelValue), not from
    /// the monthly counter, so this only tracks the legacy derived-weekly
    /// samples path. Currently unused while xAI reports a native weekly
    /// window; kept so the rolling-consumption helper stays exercised.
    private func updateXaiDerived(_ snap: UsageSnapshot) {
        guard snap.reports.contains(where: { $0.provider == "xai-oauth" }) else {
            xaiWeeklyUsed = nil
            xaiNativeWeekly = false
            return
        }
        xaiNativeWeekly = true
        xaiWeeklyUsed = nil
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

    private func persistOpenRouter(_ credits: OpenRouter.Credits) {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmpUsageBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let state = PersistedOpenRouter(
            updatedAt: Date(),
            totalCredits: credits.totalCredits,
            totalUsage: credits.totalUsage,
            remaining: credits.remaining,
            usedFraction: credits.usedFraction
        )
        if let data = try? encoder.encode(state) {
            try? data.write(to: dir.appendingPathComponent("openrouter.json"))
        }
    }
}
