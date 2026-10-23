import Foundation
import OmpUsageCore

func expect(_ cond: @autoclosure () -> Bool, _ message: String) {
    if !cond() {
        fputs("FAIL \(message)\n", stderr)
        exit(1)
    }
}

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ message: String) {
    expect(got == want, "\(message): got \(got), want \(want)")
}

func expectClose(_ got: Double, _ want: Double, _ message: String, accuracy: Double = 1e-9) {
    expect(abs(got - want) <= accuracy, "\(message): got \(got), want \(want)")
}

switch NerfTrack.measureInterval(
    previousCostUsd: 1,
    currentCostUsd: 1.42,
    previousUsedPercent: 42,
    currentUsedPercent: 43
) {
case let .valid(costDelta, _, estimate):
    expectClose(costDelta, 0.42, "cost delta")
    expectClose(estimate, 42, "weekly projection")
default:
    fputs("FAIL expected valid interval\n", stderr)
    exit(1)
}

switch NerfTrack.measureInterval(
    previousCostUsd: 1,
    currentCostUsd: 1.21,
    previousUsedPercent: 12.25,
    currentUsedPercent: 12.75
) {
case let .valid(_, _, estimate):
    expectClose(estimate, 42, "decimal percent projection")
default:
    fputs("FAIL expected valid decimal interval\n", stderr)
    exit(1)
}

expectEqual(
    NerfTrack.measureInterval(
        previousCostUsd: 1,
        currentCostUsd: 1,
        previousUsedPercent: 1,
        currentUsedPercent: 2
    ),
    .pending,
    "zero cost delta is pending"
)

expectEqual(
    NerfTrack.measureInterval(
        previousCostUsd: 1,
        currentCostUsd: 2,
        previousUsedPercent: 42,
        currentUsedPercent: 41
    ),
    .rejected,
    "usage decrease is rejected"
)

expectEqual(NerfTrack.medianRecent([42, 41, 43, 4200, 40]), 42, "median resists outlier")

let unpaired = NerfTrack.estimate(
    observations: [
        .init(timestampMs: 1_000, usedPercent: 0, resetAtMs: 100_000),
        .init(timestampMs: 2_000, usedPercent: 10, resetAtMs: 100_000),
        .init(timestampMs: 3_000, usedPercent: 20, resetAtMs: 100_000),
        .init(timestampMs: 4_000, usedPercent: 0, resetAtMs: 200_000),
        .init(timestampMs: 5_000, usedPercent: 50, resetAtMs: 200_000),
    ],
    costs: [
        .init(timestampMs: 1_500, costUsd: 4.2),
        .init(timestampMs: 2_500, costUsd: 4.2),
    ]
)
expectEqual(unpaired.status, .pending, "unpaired current window")
expectClose(unpaired.lastCalibratedUsd ?? -1, 42, "last calibrated window")
expect(unpaired.estimatedWeeklyValueUsd == nil, "current estimate stays nil")
expectClose(unpaired.weeklyUsedPercent ?? -1, 50, "current used percent")

let paired = NerfTrack.estimate(
    observations: [
        .init(timestampMs: 1_000, usedPercent: 10, resetAtMs: 100_000),
        .init(timestampMs: 2_000, usedPercent: 20, resetAtMs: 100_000),
    ],
    costs: [
        .init(timestampMs: 1_500, costUsd: 5),
    ]
)
expectEqual(paired.status, .valid, "paired window")
expectClose(paired.estimatedWeeklyValueUsd ?? -1, 50, "paired estimate")
expectEqual(paired.confidence, .low, "single observation is low confidence")

let live = NerfTrack.loadFromOmp()
print("live status=\(live.status.rawValue) current=\(live.estimatedWeeklyValueUsd.map { String($0) } ?? "nil") last=\(live.lastCalibratedUsd.map { String($0) } ?? "nil") used=\(live.weeklyUsedPercent.map { String($0) } ?? "nil") n=\(live.validObservationCount) note=\(live.note)")
if live.status != .empty {
    if let last = live.lastCalibratedUsd {
        expect(last > 1 && last < 10_000, "live last calibrated is sane")
    }
    if let used = live.weeklyUsedPercent {
        expect(used >= 0 && used <= 100, "live used percent is a percent")
    }
}

expectClose(GoCatalog.lookup("opencode-go/deepseek-v4-flash")?.includedMonthlyUsd ?? -1, 30, "flash is $30 included")
expectClose(GoCatalog.lookup("opencode-go/deepseek-v4-flash")?.multiplier ?? -1, 3, "flash is 3×")
expectClose(GoCatalog.lookup("glm-5.2")?.includedMonthlyUsd ?? -1, 60, "glm-5.2 is $60 included")

let shared: [NerfTrack.Observation] = [
    .init(timestampMs: 1_000, usedPercent: 0, resetAtMs: 100_000),
    .init(timestampMs: 2_000, usedPercent: 10, resetAtMs: 100_000),
]
let sliced = ModelValue.estimate(
    provider: "opencode-go",
    windowId: "weekly",
    observations: shared,
    events: [
        .init(timestampMs: 1_500, model: "deepseek-v4-flash", costUsd: 1, inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0),
        .init(timestampMs: 1_600, model: "glm-5.2", costUsd: 1, inputTokens: 1_000_000, outputTokens: 0, cacheReadTokens: 0),
    ]
)
expectEqual(sliced.count, 2, "two models")
let flash = sliced.first { $0.modelId == "deepseek-v4-flash" }!
let glm = sliced.first { $0.modelId == "glm-5.2" }!
expectClose(flash.deliveredUsd, 0.22, "flash delivered list $0.22 for 1M input")
expectClose(glm.deliveredUsd, 1.40, "glm delivered list $1.40 for 1M input")
expectClose(flash.catalogIncludedMonthlyUsd ?? -1, 30, "flash catalog")
expectClose(glm.catalogIncludedMonthlyUsd ?? -1, 60, "glm catalog")
expect(flash.deliveredUsd < 5, "flash delivered is not a full-pool extrapolation")

let liveBundles = ModelValue.loadFromOmp()
print("bundleCount=\(liveBundles.count)")
for bundle in liveBundles {
    print("bundle \(bundle.provider) \(bundle.windowLabel) \(bundle.windowId)")
    for item in bundle.models {
        let catalog = item.catalogIncludedMonthlyUsd.map { String(Int($0)) } ?? "-"
        print("  \(item.displayName) delivered=\(String(format: "%.2f", item.deliveredUsd)) catalog=$\(catalog) \(item.note)")
    }
}

print("ok")
