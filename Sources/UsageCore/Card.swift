import Foundation

/// One card in the dropdown. The store holds each provider's result; a card
/// says which result it belongs to and in what order to draw it.
public enum Card: Equatable, Sendable, Identifiable {
    case claude
    case openCodeGo
    case codexSeat(email: String)
    case openRouter
    case link(Config.Link)

    /// A stable identity for `ForEach`; each configured card appears once, so
    /// a provider's id is the name the config file uses for it.
    public var id: String {
        switch self {
        case .claude: return Config.Provider.claude.rawValue
        case .openCodeGo: return Config.Provider.openCodeGo.rawValue
        case .codexSeat(let email): return "\(Config.Provider.codex.rawValue):\(email)"
        case .openRouter: return Config.Provider.openRouter.rawValue
        case .link(let link): return "link:\(link.title):\(link.url.absoluteString)"
        }
    }
}

extension Config {
    /// The cards the dropdown shows, in order: each configured provider once
    /// (Codex expands to one card per seat, labeled by email), then the
    /// config's links. A card is listed for every configured provider even
    /// before its first result arrives; until then it draws a placeholder.
    public func cards(codexSeats: [String]) -> [Card] {
        var cards: [Card] = []
        for provider in providers {
            switch provider {
            case .claude:
                cards.append(.claude)
            case .openCodeGo:
                cards.append(.openCodeGo)
            case .codex:
                cards.append(contentsOf: codexSeats.map(Card.codexSeat(email:)))
            case .openRouter:
                cards.append(.openRouter)
            }
        }
        cards.append(contentsOf: links.map(Card.link))
        return cards
    }
}
