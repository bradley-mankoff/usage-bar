import Foundation

/// Reads API keys and tokens from where pi and Claude Code already keep them.
/// Keys are never logged or written anywhere by the bar.
enum Credentials {
    /// A generic-password item from the login Keychain. Runs
    /// `/usr/bin/security` rather than calling SecItemCopyMatching: the
    /// Keychain allows the system `security` tool silently, while a freshly
    /// rebuilt, ad-hoc-signed app would get a permission prompt on every build.
    static func keychain(service: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Every entry in pi's `~/.pi/agent/auth.json`, keyed by provider name.
    /// pi refreshes its OAuth entries whenever it uses them; the bar only reads.
    static func piAuth() -> [String: [String: Any]] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/auth.json")
        guard let data = try? Data(contentsOf: url),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return auth.compactMapValues { $0 as? [String: Any] }
    }

    /// The `key` of an api_key entry in pi's auth.json.
    static func piApiKey(provider: String) -> String? {
        guard let key = piAuth()[provider]?["key"] as? String, !key.isEmpty else { return nil }
        return key
    }

    static func env(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name]
        return value?.isEmpty == false ? value : nil
    }
}
