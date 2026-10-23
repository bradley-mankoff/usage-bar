import SwiftUI
import AppKit
import OmpUsageCore

struct ContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.snapshot == nil {
                statusBanner
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(sortedReports, id: \.provider) { report in
                        providerSection(report)
                    }
                    openRouterSection
                    if sortedReports.isEmpty && !showOpenRouter {
                        Text("No usage data yet — is `omp` authenticated?")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    }
                }
                .padding(12)
            }
            .frame(width: 380)
            .frame(maxHeight: 800)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer
        }
    }

    /// Active subscriptions first; ended ones sink to the bottom.
    private var sortedReports: [ProviderReport] {
        (store.snapshot?.reports ?? []).sorted {
            ($0.isInactive ? 1 : 0) < ($1.isInactive ? 1 : 0)
        }
    }

    /// Show OpenRouter whenever we have credits, a key, or omp lists the
    /// account as having no usage data (its way of saying "API key").
    private var showOpenRouter: Bool {
        if store.openRouter != nil || store.openRouterKeyFound { return true }
        return store.snapshot?.accountsWithoutUsage?.contains {
            $0.provider == "openrouter"
        } ?? false
    }

    @ViewBuilder
    private var statusBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(store.errorMessage ?? "Fetching usage\u{2026}")
        }
        .font(.caption)
        .foregroundColor(.red)
        .padding(10)
    }

    private var footer: some View {
        HStack {
            Text(updatedText)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if store.errorMessage != nil {
                Text(store.errorMessage ?? "")
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("Refresh") { store.refresh() }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(8)
    }

    private var updatedText: String {
        guard let last = store.lastUpdated else { return "Not updated yet" }
        let secs = Int(Date().timeIntervalSince(last))
        if secs < 5 { return "Updated just now" }
        if secs < 60 { return "Updated \(secs)s ago" }
        if secs < 3600 { return "Updated \(secs / 60)m ago" }
        return "Updated \(secs / 3600)h ago"
    }

    @ViewBuilder
    private func providerSection(_ report: ProviderReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(displayName(report.provider)).font(.headline)
                Spacer()
                if report.isInactive {
                    Text("Subscription ended")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if let plan = report.metadata?.planType {
                    Text(plan).font(.caption).foregroundColor(.secondary)
                }
            }
            if report.isInactive {
                Text("Inactive — ended plan. Not counted in the menu-bar %.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if let email = report.metadata?.email {
                Text(email).font(.caption).foregroundColor(.secondary)
            }
            ForEach(report.limits, id: \.id) { limit in
                limitRow(limit)
            }
            if report.provider == "xai-oauth" {
                xaiValueRow
            }
            if report.provider == "openai-codex" {
                nerfTrackRow
            }
            ForEach(store.bundles(for: report.provider).filter { $0.windowLabel == "week" }) { bundle in
                modelValueSection(bundle)
            }
            if let notes = report.notes, !notes.isEmpty {
                ForEach(notes, id: \.self) { note in
                    Text(note).font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05))
        )
    }

    @ViewBuilder
    private var openRouterSection: some View {
        if showOpenRouter {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("OpenRouter").font(.headline)
                    Spacer()
                    Text("pay-as-you-go").font(.caption).foregroundColor(.secondary)
                }
                if let credits = store.openRouter {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Credits").font(.callout)
                        Spacer()
                        Text("$\(fmt2(credits.remaining)) left of $\(fmt2(credits.totalCredits))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(severity(credits.usedFraction))
                    }
                    if let frac = credits.usedFraction {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.12))
                                Capsule()
                                    .fill(severity(frac))
                                    .frame(width: max(geo.size.width * CGFloat(min(max(frac, 0), 1)), 4))
                            }
                        }
                        .frame(height: 6)
                    }
                    Text("omp reports no usage for API-key providers; fetched from OpenRouter directly.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("Fetching OpenRouter credits\u{2026}")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05))
            )
        }
    }

    @ViewBuilder
    private func limitRow(_ limit: LimitReport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.label).font(.callout)
                Spacer()
                Text(detailText(limit))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(severity(limit.amount?.usedFraction))
            }
            if let frac = limit.amount?.usedFraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule()
                            .fill(severity(frac))
                            .frame(width: max(geo.size.width * CGFloat(min(max(frac, 0), 1)), 4))
                    }
                }
                .frame(height: 6)
            }
            if let resets = resetsIn(limit.window?.resetsAt) {
                Text(resets).font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    /// xAI API value this cycle: weekly pool percent burned times the
    /// API-equivalent monthly value, scaled to one week. The pool percent is
    /// the source of truth: omp only logs tokens for CLI-driven usage, so
    /// repricing token rows undercounts everything done on grok.com/X/apps.
    /// A per-model token breakdown follows in "Delivered this week" when the
    /// current cycle has priced token rows.
    @ViewBuilder
    private var xaiValueRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("API value this cycle").font(.callout)
                Spacer()
                Text(xaiValueText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(xaiPoolValue == nil ? .secondary : .primary)
            }
            Text("Weekly pool used × API-equiv value, scaled to one week.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    /// Weekly pool fraction burned times the subscription's API-equivalent
    /// monthly value, scaled to one week (weekly pool ≈ monthly / 4).
    private var xaiPoolValue: Double? {
        guard let report = store.snapshot?.reports.first(where: { $0.provider == "xai-oauth" }),
              let frac = SubscriptionValue.weeklyFraction(limits: report.limits.map {
                  ($0.window?.id, $0.id, $0.amount?.usedFraction)
              }),
              let monthly = SubscriptionValue.valueUsd(provider: "xai-oauth", planType: report.metadata?.planType)
        else { return nil }
        return frac * monthly / 4
    }

    private var xaiValueText: String {
        guard let total = xaiPoolValue else { return "\u{2014}" }
        return "\u{2248}$\(fmt0(total))"
    }

    @ViewBuilder
    private var nerfTrackRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("API-equivalent / week").font(.callout)
                Spacer()
                Text(nerfTrackValue)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(store.nerfTrack?.status == .valid ? .primary : .secondary)
            }
            Text(store.nerfTrack?.note ?? "Estimating local Codex token cost\u{2026}")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var nerfTrackValue: String {
        guard let quote = store.nerfTrack else { return "\u{2014}" }
        if let current = quote.estimatedWeeklyValueUsd {
            return "\u{2248}$\(fmt0(current))"
        }
        if let last = quote.lastCalibratedUsd {
            return "last \u{2248}$\(fmt0(last))"
        }
        return "\u{2014}"
    }

    private func fmt0(_ value: Double) -> String {
        String(format: "%.0f", value.rounded())
    }

    @ViewBuilder
    private func modelValueSection(_ bundle: ModelValue.Bundle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Delivered this \(bundle.windowLabel)")
                .font(.caption2)
                .foregroundColor(.secondary)
            ForEach(bundle.models) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.displayName).font(.callout)
                    Spacer()
                    if let mult = item.catalogMultiplier {
                        Text(mult == mult.rounded() ? "\(Int(mult))\u{00D7}" : String(format: "%.1f\u{00D7}", mult))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text("$\(fmt2(item.deliveredUsd))")
                        .font(.caption)
                        .monospacedDigit()
                }
            }
            if let note = bundle.models.first?.note {
                Text(note)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func detailText(_ limit: LimitReport) -> String {
        var parts: [String] = []
        if let amount = limit.amount {
            let used = amount.used ?? 0
            let text: String
            switch amount.unit {
            case "usd":
                text = "$\(fmt2(used)) / $\(fmt2(amount.limit ?? 0))"
            case "percent":
                text = "\(fmtNum(used))% / \(fmtNum(amount.limit ?? 0))%"
            default:
                text = "\(fmtNum(used)) / \(fmtNum(amount.limit ?? 0))"
            }
            parts.append(text)
            if let frac = amount.usedFraction {
                parts.append("\(pctString(frac)) used")
            }
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func resetsIn(_ resetsAt: Int64?) -> String? {
        guard let resetsAt else { return nil }
        let secs = Int((resetsAt - Int64(Date().timeIntervalSince1970 * 1000)) / 1000)
        if secs <= 0 { return "resets now" }
        if secs < 60 { return "resets in \(secs)s" }
        let m = secs / 60
        if m < 60 { return "resets in \(m)m" }
        let h = m / 60
        if h < 24 { return "resets in \(h)h\(m % 60)m" }
        let d = h / 24
        return "resets in \(d)d\(h % 24)h"
    }

    private func severity(_ frac: Double?) -> Color {
        guard let frac else { return .secondary }
        if frac >= 0.85 { return .red }
        if frac >= 0.6 { return .orange }
        return .green
    }

    private func displayName(_ provider: String) -> String {
        switch provider {
        case "openai-codex": return "OpenAI Codex"
        case "opencode-go": return "OpenCode Go"
        case "openrouter": return "OpenRouter"
        case "xai-oauth": return "Xai OAuth"
        default:
            return provider.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
        }
    }

    private func pctString(_ frac: Double) -> String {
        let pct = frac * 100
        return pct < 10 ? String(format: "%.1f%%", pct) : String(format: "%.0f%%", pct)
    }

    private func fmt2(_ value: Double) -> String { String(format: "%.2f", value) }

    private func fmtNum(_ value: Double) -> String {
        value.rounded() == value
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }
}
