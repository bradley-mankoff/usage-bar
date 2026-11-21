import Foundation

/// What the bar shows and where it reads from, loaded from
/// `~/.config/usage-bar/config.json` at launch. Every key is optional; a
/// missing file, an unreadable one or a malformed key falls back to the
/// default it would have had without a config file at all.
public struct Config: Equatable, Sendable {
    /// A usage source the bar can poll. The string values are the ones the
    /// config file uses.
    public enum Provider: String, CaseIterable, Sendable {
        case claude
        case openCodeGo = "opencode-go"
        case codex
        case openRouter = "openrouter"

        /// The heading of the provider's card in the dropdown.
        public var title: String {
            switch self {
            case .claude: return "Claude"
            case .openCodeGo: return "OpenCode Go"
            case .codex: return "Codex"
            case .openRouter: return "OpenRouter"
            }
        }

        /// The windows `MenuBarLabel` makes the bar text from, in display
        /// order. The ids must match the ones the provider's parser emits.
        public var menuBarWindowIDs: [String] {
            switch self {
            case .claude: return ["five_hour", "seven_day"]
            case .openCodeGo: return ["rolling", "weekly"]
            case .codex: return ["openai-codex:primary_window", "openai-codex:secondary_window"]
            case .openRouter: return [OpenRouter.balanceWindowID]
            }
        }
    }

    /// A card that only opens a URL; it has no usage to poll.
    public struct Link: Equatable, Sendable {
        public var title: String
        public var url: URL

        public init(title: String, url: URL) {
            self.title = title
            self.url = url
        }
    }

    /// Every provider, in the order the bar has always shown them. The
    /// config's `providers` replaces this list and its order.
    public static let defaultProviders: [Provider] = Provider.allCases

    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/usage-bar/config.json")
    }

    public static var `default`: Config {
        Config(
            providers: defaultProviders,
            menuBar: .claude,
            piAuthFile: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pi/agent/auth.json"),
            refreshSeconds: 300,
            links: []
        )
    }

    /// Providers to poll, in the order their cards appear. Only these are
    /// polled and only their credentials are read.
    public var providers: [Provider]
    /// The provider whose first two windows make up the menu bar text.
    public var menuBar: Provider
    /// pi's auth.json: the OAuth tokens and API keys for pi's providers.
    public var piAuthFile: URL
    /// How often every configured provider is polled.
    public var refreshSeconds: Int
    /// Extra cards after the provider cards, each a title and the URL its
    /// open button opens.
    public var links: [Link]

    public init(
        providers: [Provider], menuBar: Provider, piAuthFile: URL,
        refreshSeconds: Int, links: [Link]
    ) {
        self.providers = providers
        self.menuBar = menuBar
        self.piAuthFile = piAuthFile
        self.refreshSeconds = refreshSeconds
        self.links = links
    }

    /// Reads the config file at `url`, falling back to `default` key by key.
    /// Unknown provider names are dropped; an empty `providers` list means no
    /// provider cards, which is different from leaving the key out.
    public static func load(from url: URL = defaultPath) -> Config {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .default }

        var config = Config.default
        if let names = root["providers"] as? [String] {
            config.providers = names.compactMap(Provider.init(rawValue:))
        }
        if let name = root["menuBar"] as? String, let provider = Provider(rawValue: name) {
            config.menuBar = provider
        }
        if let path = root["piAuthFile"] as? String, !path.isEmpty {
            config.piAuthFile = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if let seconds = (root["refreshSeconds"] as? NSNumber)?.intValue {
            // A non-positive interval would make the timer fire continuously.
            config.refreshSeconds = max(1, seconds)
        }
        if let entries = root["links"] as? [[String: Any]] {
            config.links = entries.compactMap { entry in
                guard let title = entry["title"] as? String, !title.isEmpty,
                      let text = entry["url"] as? String,
                      let url = URL(string: text)
                else { return nil }
                return Link(title: title, url: url)
            }
        }
        return config
    }
}
