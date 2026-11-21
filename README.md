# usage-bar

usage-bar is a macOS menu bar item that shows how much of each AI subscription or credit
balance is used. With no configuration its label is Claude's five-hour then weekly percent, and
its menu holds one card per provider that has a credential on this Mac: Claude, every ChatGPT
(Codex) seat, OpenCode Go and OpenRouter. It reads every credential from where pi
(by default `~/.pi/agent/auth.json`) and Claude Code (the login Keychain item
`Claude Code-credentials`) already keep it, never refreshes or writes one, and refreshes every
five minutes. A provider with no credential, or whose sign-in has expired, is hidden rather
than shown as an error. A config file can choose the providers, the menu bar label, the pi
auth file, the refresh interval and extra link cards; see [Configuration](#configuration).

## Install

```sh
./install.sh
```

That builds the app with `swift build -c release`, installs it as
`~/Applications/UsageBar.app`, signs it ad hoc, and loads the login job
`com.bradley-mankoff.usagebar` from `~/Library/LaunchAgents`, which opens it at login and
restarts it after a crash. It needs macOS 13 or later and a Swift toolchain
(`xcode-select --install`).

To remove it, run `launchctl bootout gui/$(id -u)/com.bradley-mankoff.usagebar`, then delete
`~/Applications/UsageBar.app` and `~/Library/LaunchAgents/com.bradley-mankoff.usagebar.plist`.

## Configuration

usage-bar reads `~/.config/usage-bar/config.json` when it launches. Every key is optional:
without a file the bar shows every provider that has a credential, labels itself with Claude,
reads pi's auth file and refreshes every five minutes. Edit the file, then restart the bar;
it is not watched while running.

| Key | Default | Meaning |
| --- | --- | --- |
| `providers` | `["claude", "opencode-go", "codex", "openrouter"]` | The providers to poll, in the order their cards appear in the menu. Only these providers are polled and only their credentials are read. Codex draws one card per seat. An empty list shows no provider cards. |
| `menuBar` | `"claude"` | Which provider's windows the menu bar label shows, using that provider's first two windows: Claude's five-hour then weekly, OpenCode Go's rolling then weekly, the first Codex seat's five-hour then weekly, or OpenRouter's share of its credits used. If that provider is not in `providers`, the label shows `?`. |
| `piAuthFile` | `"~/.pi/agent/auth.json"` | pi's auth file: the OAuth logins and API keys the bar reads for Claude, Codex, OpenCode Go and OpenRouter. The Claude Code Keychain item is still read when `claude` is polled. |
| `refreshSeconds` | `300` | How often the configured providers are polled, in seconds. |
| `links` | `[]` | Extra cards after the provider cards. Each entry has a `title` and a `url`, and the card's Open button opens the URL in the default browser. |

A config that pins every key and adds a link card:

```json
{
  "providers": ["claude", "opencode-go", "codex", "openrouter"],
  "menuBar": "claude",
  "piAuthFile": "~/.pi/agent/auth.json",
  "refreshSeconds": 300,
  "links": [
    {"title": "OpenAI usage", "url": "https://platform.openai.com/usage"}
  ]
}
```

## Tests

```sh
swift test
```

## Acknowledgements

- The `usage` command of [oh-my-pi](https://github.com/can1357/oh-my-pi) by can1357 was this
  bar's first data source and showed which usage endpoints the providers answer.
- [pi](https://github.com/earendil-works/pi) by Mario Zechner and
  [Claude Code](https://github.com/anthropics/claude-code) keep the sign-ins the bar reads.

The usage endpoints the bar calls are the ones the providers' own apps use, not documented
public APIs, so a provider can change them at any time. usage-bar is not affiliated with
Anthropic, OpenAI, OpenCode or OpenRouter.

## License

MIT. See [LICENSE](LICENSE).
