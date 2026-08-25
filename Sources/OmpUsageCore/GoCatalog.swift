import Foundation

/// Published OpenCode Go list rates and per-model included monthly usage.
/// Source: https://opencode.ai/docs/go/ (verified 2026-08-17)
///
/// The $12 / $30 / $60 limits are one shared dollar pool. The Usage column is
/// the list-price monthly value they assign to that pool when spent on one model
/// ($60 = 6× the $10 sub, $30 = 3×, $15 = 1.5×).
public enum GoCatalog {
    public static let monthlyPoolUsd = 60.0
    public static let weeklyPoolUsd = 30.0
    public static let subscriptionUsd = 10.0

    public struct Model: Equatable, Sendable {
        public var id: String
        public var displayName: String
        public var includedMonthlyUsd: Double
        public var inputPerM: Double
        public var outputPerM: Double
        public var cachedReadPerM: Double
        public var cachedWritePerM: Double?

        public var multiplier: Double { includedMonthlyUsd / subscriptionUsd }
    }

    public static let models: [Model] = [
        .init(id: "grok-4.5", displayName: "Grok 4.5", includedMonthlyUsd: 15, inputPerM: 2, outputPerM: 6, cachedReadPerM: 0.30, cachedWritePerM: nil),
        .init(id: "gpt-5.6-luna", displayName: "GPT 5.6 Luna", includedMonthlyUsd: 15, inputPerM: 0.20, outputPerM: 1.20, cachedReadPerM: 0.02, cachedWritePerM: 0.25),
        .init(id: "glm-5.3", displayName: "GLM-5.3", includedMonthlyUsd: 15, inputPerM: 1.40, outputPerM: 4.40, cachedReadPerM: 0.26, cachedWritePerM: nil),
        .init(id: "glm-5.2", displayName: "GLM-5.2", includedMonthlyUsd: 60, inputPerM: 1.40, outputPerM: 4.40, cachedReadPerM: 0.26, cachedWritePerM: nil),
        .init(id: "glm-5.1", displayName: "GLM-5.1", includedMonthlyUsd: 60, inputPerM: 1.40, outputPerM: 4.40, cachedReadPerM: 0.26, cachedWritePerM: nil),
        .init(id: "kimi-k3", displayName: "Kimi K3", includedMonthlyUsd: 15, inputPerM: 3, outputPerM: 15, cachedReadPerM: 0.30, cachedWritePerM: nil),
        .init(id: "kimi-k2.7-code", displayName: "Kimi K2.7 Code", includedMonthlyUsd: 60, inputPerM: 0.95, outputPerM: 4, cachedReadPerM: 0.19, cachedWritePerM: nil),
        .init(id: "kimi-k2.6", displayName: "Kimi K2.6", includedMonthlyUsd: 60, inputPerM: 0.95, outputPerM: 4, cachedReadPerM: 0.16, cachedWritePerM: nil),
        .init(id: "mimo-v2.5", displayName: "MiMo V2.5", includedMonthlyUsd: 60, inputPerM: 0.14, outputPerM: 0.28, cachedReadPerM: 0.0028, cachedWritePerM: nil),
        .init(id: "mimo-v2.5-pro", displayName: "MiMo V2.5 Pro", includedMonthlyUsd: 15, inputPerM: 0.435, outputPerM: 0.87, cachedReadPerM: 0.003625, cachedWritePerM: nil),
        .init(id: "minimax-m3", displayName: "MiniMax M3", includedMonthlyUsd: 60, inputPerM: 0.30, outputPerM: 1.20, cachedReadPerM: 0.06, cachedWritePerM: nil),
        .init(id: "minimax-m2.7", displayName: "MiniMax M2.7", includedMonthlyUsd: 60, inputPerM: 0.30, outputPerM: 1.20, cachedReadPerM: 0.06, cachedWritePerM: 0.375),
        .init(id: "minimax-m2.5", displayName: "MiniMax M2.5", includedMonthlyUsd: 60, inputPerM: 0.30, outputPerM: 1.20, cachedReadPerM: 0.06, cachedWritePerM: 0.375),
        .init(id: "qwen3.8-max", displayName: "Qwen3.8 Max", includedMonthlyUsd: 15, inputPerM: 2, outputPerM: 6, cachedReadPerM: 0.25, cachedWritePerM: 2.50),
        .init(id: "qwen3.7-max", displayName: "Qwen3.7 Max", includedMonthlyUsd: 60, inputPerM: 2.50, outputPerM: 7.50, cachedReadPerM: 0.50, cachedWritePerM: 3.125),
        .init(id: "qwen3.7-plus", displayName: "Qwen3.7 Plus", includedMonthlyUsd: 60, inputPerM: 0.40, outputPerM: 1.60, cachedReadPerM: 0.04, cachedWritePerM: 0.50),
        .init(id: "qwen3.6-plus", displayName: "Qwen3.6 Plus", includedMonthlyUsd: 60, inputPerM: 0.50, outputPerM: 3, cachedReadPerM: 0.05, cachedWritePerM: 0.625),
        .init(id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", includedMonthlyUsd: 15, inputPerM: 0.66, outputPerM: 1.98, cachedReadPerM: 0.022, cachedWritePerM: nil),
        .init(id: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash", includedMonthlyUsd: 30, inputPerM: 0.22, outputPerM: 0.66, cachedReadPerM: 0.007, cachedWritePerM: nil),
        .init(id: "hy3", displayName: "Hy3", includedMonthlyUsd: 60, inputPerM: 0.14, outputPerM: 0.58, cachedReadPerM: 0.035, cachedWritePerM: nil),
    ]

    public static func lookup(_ rawId: String) -> Model? {
        let id = normalize(rawId)
        return models.first { $0.id == id }
    }

    public static func normalize(_ rawId: String) -> String {
        var id = rawId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let slash = id.lastIndex(of: "/") {
            id = String(id[id.index(after: slash)...])
        }
        return id
    }

    public static func displayName(_ rawId: String) -> String {
        lookup(rawId)?.displayName ?? rawId
    }
}
