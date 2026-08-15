import SwiftUI
import AppKit

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
                    ForEach(store.snapshot?.reports ?? [], id: \.provider) { report in
                        providerSection(report)
                    }
                    if store.snapshot?.reports.isEmpty ?? true {
                        Text("No usage data yet — is `omp` authenticated?")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    }
                }
                .padding(12)
            }
            .frame(width: 360, height: 300)
            Divider()
            footer
        }
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
                if let plan = report.metadata?.planType {
                    Text(plan).font(.caption).foregroundColor(.secondary)
                }
            }
            if let email = report.metadata?.email {
                Text(email).font(.caption).foregroundColor(.secondary)
            }
            ForEach(report.limits, id: \.id) { limit in
                limitRow(limit)
            }
            if report.provider == "xai-oauth" && !store.xaiNativeWeekly {
                derivedWeeklyRow
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

    @ViewBuilder
    private var derivedWeeklyRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 7 days").font(.callout)
                Spacer()
                if let used = store.xaiWeeklyUsed {
                    Text(fmtNum(used)).font(.caption).monospacedDigit()
                } else {
                    Text("\u{2014}").font(.caption).foregroundColor(.secondary)
                }
            }
            Text(store.xaiWeeklyUsed == nil
                 ? "Collecting samples\u{2026} derived from the monthly counter (xAI exposes no weekly quota here)."
                 : "Derived from the monthly counter (xAI exposes no weekly quota here).")
                .font(.caption2)
                .foregroundColor(.secondary)
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
