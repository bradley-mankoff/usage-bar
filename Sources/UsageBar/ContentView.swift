import SwiftUI
import AppKit
import UsageCore

struct ContentView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    subscriptionSection("Claude", store.claude)
                    subscriptionSection("OpenCode Go", store.openCodeGo)
                    ForEach(store.codexSeats) { seat in
                        subscriptionSection("Codex", seat.result, subtitle: seat.email)
                    }
                    openRouterSection
                    jevSection
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

    private var footer: some View {
        HStack {
            Text(updatedText)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Refresh") { store.refresh() }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(8)
    }

    private var updatedText: String {
        guard let last = store.lastUpdated else { return "Fetching\u{2026}" }
        let secs = Int(Date().timeIntervalSince(last))
        if secs < 5 { return "Updated just now" }
        if secs < 60 { return "Updated \(secs)s ago" }
        if secs < 3600 { return "Updated \(secs / 60)m ago" }
        return "Updated \(secs / 3600)h ago"
    }

    private func card<Content: View>(
        _ title: String, _ subtitle: String?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    /// Nil while loading shows a placeholder; nil after the first fetch hides
    /// the section (no credential on this machine).
    @ViewBuilder
    private func subscriptionSection(
        _ title: String, _ result: Result<SubscriptionUsage, Error>?, subtitle: String? = nil
    ) -> some View {
        switch result {
        case nil:
            if !store.firstFetchDone {
                card(title, subtitle) { placeholder("Fetching\u{2026}") }
            }
        case .failure(let error):
            card(title, subtitle) { errorText(error) }
        case .success(let sub):
            card(title, sub.plan ?? subtitle) {
                if let note = sub.note {
                    Text(note).font(.caption).foregroundColor(.orange)
                }
                if sub.windows.isEmpty {
                    Text("No rate-limit windows reported.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(sub.windows) { window in
                    meterRow(
                        window.label,
                        detail: "\(pctString(window.usedFraction)) used",
                        fraction: window.usedFraction,
                        footnote: resetsIn(window.resetsAt)
                    )
                }
                if !sub.resetCredits.isEmpty {
                    resetCreditsRows(sub.resetCredits)
                }
            }
        }
    }

    @ViewBuilder
    private var openRouterSection: some View {
        switch store.openRouter {
        case nil:
            if !store.firstFetchDone {
                card("OpenRouter", "credits") { placeholder("Fetching\u{2026}") }
            }
        case .failure(let error):
            card("OpenRouter", "credits") { errorText(error) }
        case .success(let credits):
            card("OpenRouter", "credits") {
                meterRow(
                    "Balance",
                    detail: "$\(fmt2(credits.remaining)) left of $\(fmt2(credits.totalCredits))",
                    fraction: credits.usedFraction,
                    footnote: nil
                )
            }
        }
    }

    /// TypeSafe's API has no balance endpoint (only /v1/models and
    /// /v1/systemone, checked 2026-10-23), so this links to the console.
    private var jevSection: some View {
        card("Jev", "credits") {
            HStack(alignment: .firstTextBaseline) {
                Text("TypeSafe has no balance API.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Open console") {
                    NSWorkspace.shared.open(URL(string: "https://console.typesafe.ai/usage")!)
                }
                .font(.caption)
            }
        }
    }

    private func meterRow(_ label: String, detail: String, fraction: Double?, footnote: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.callout)
                Spacer()
                Text(detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(severity(fraction))
            }
            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule()
                            .fill(severity(fraction))
                            .frame(width: max(geo.size.width * CGFloat(min(max(fraction, 0), 1)), 4))
                    }
                }
                .frame(height: 6)
            }
            if let footnote {
                Text(footnote).font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    /// One line per banked reset, soonest expiry first; orange when it
    /// expires within two days, so it gets used rather than lost.
    private func resetCreditsRows(_ credits: [ResetCredit]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(credits.count == 1 ? "1 reset available" : "\(credits.count) resets available")
                .font(.callout)
            ForEach(Array(credits.enumerated()), id: \.offset) { _, credit in
                Text("\(credit.title) \u{00B7} \(expiryText(credit.expiresAt))")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundColor(
                        (credit.expiresAt?.timeIntervalSinceNow ?? .infinity) < 2 * 86400 ? .orange : .secondary
                    )
            }
        }
        .padding(.top, 2)
    }

    private func expiryText(_ date: Date?) -> String {
        guard let date else { return "no expiry date" }
        let when = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        return "expires \(when) (\(timeLeft(date)))"
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.callout).foregroundColor(.secondary)
    }

    private func errorText(_ error: Error) -> some View {
        Text(error.localizedDescription).font(.caption).foregroundColor(.red)
    }

    private func resetsIn(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.timeIntervalSinceNow <= 0 ? "resets now" : "resets \(timeLeft(date))"
    }

    /// "in 5m", "in 3h12m", "in 1d2h"; "now" once past.
    private func timeLeft(_ date: Date) -> String {
        let secs = Int(date.timeIntervalSinceNow)
        if secs <= 0 { return "now" }
        if secs < 60 { return "in \(secs)s" }
        let m = secs / 60
        if m < 60 { return "in \(m)m" }
        let h = m / 60
        if h < 24 { return "in \(h)h\(m % 60)m" }
        return "in \(h / 24)d\(h % 24)h"
    }

    private func severity(_ frac: Double?) -> Color {
        guard let frac else { return .secondary }
        if frac >= 0.85 { return .red }
        if frac >= 0.6 { return .orange }
        return .green
    }

    private func pctString(_ frac: Double) -> String {
        let pct = frac * 100
        return pct < 10 ? String(format: "%.1f%%", pct) : String(format: "%.0f%%", pct)
    }

    private func fmt2(_ value: Double) -> String { String(format: "%.2f", value) }
}
