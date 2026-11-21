# usage-bar

usage-bar is a macOS menu bar item that shows how much of each AI subscription or credit
balance is used. Its label is Claude's five-hour then weekly percent; its menu holds one card
per provider that has a credential on this Mac: Claude, every ChatGPT (Codex) seat, OpenCode
Go and OpenRouter. It reads every credential from where pi (`~/.pi/agent/auth.json`) and
Claude Code (the login Keychain item `Claude Code-credentials`) already keep it, never
refreshes or writes one, and refreshes every five minutes. A provider with no credential, or
whose sign-in has expired, is hidden rather than shown as an error.

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
