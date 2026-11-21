import Foundation

/// Where the bar reads credentials: a pi auth.json, the login Keychain and the
/// process environment. It reads only; keys and tokens are never logged,
/// refreshed or written anywhere by the bar.
///
/// The Keychain goes through `/usr/bin/security` rather than
/// `SecItemCopyMatching`: the Keychain allows the system `security` tool
/// silently, while a freshly rebuilt, ad-hoc-signed app would get a permission
/// prompt on every build.
struct Credentials: @unchecked Sendable {
    /// Every entry in the configured pi auth.json, keyed by provider name.
    let piAuth: [String: [String: Any]]
    private let readKeychain: (String) -> String?
    private let readEnv: (String) -> String?

    init(
        piAuth: [String: [String: Any]] = [:],
        keychain: @escaping (String) -> String? = { _ in nil },
        env: @escaping (String) -> String? = { _ in nil }
    ) {
        self.piAuth = piAuth
        self.readKeychain = keychain
        self.readEnv = env
    }

    /// This Mac's credentials, from the config's pi auth file, the login
    /// Keychain and the environment.
    static func live(config: Config) -> Credentials {
        Credentials(
            piAuth: piAuth(at: config.piAuthFile),
            keychain: keychain,
            env: { ProcessInfo.processInfo.environment[$0] }
        )
    }

    /// The same, with the Keychain and environment stood in for so a test can
    /// see which reads happen.
    static func live(
        config: Config,
        keychain: @escaping (String) -> String?,
        env: @escaping (String) -> String?
    ) -> Credentials {
        Credentials(piAuth: piAuth(at: config.piAuthFile), keychain: keychain, env: env)
    }

    /// Every entry in a pi auth.json. pi refreshes its OAuth entries whenever
    /// it uses them; the bar only reads.
    static func piAuth(at url: URL) -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return auth.compactMapValues { $0 as? [String: Any] }
    }

    /// A generic-password item from the login Keychain.
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

    func keychain(service: String) -> String? { readKeychain(service) }

    func env(_ name: String) -> String? {
        guard let value = readEnv(name), !value.isEmpty else { return nil }
        return value
    }

    /// The `key` of an api_key entry in pi's auth.json.
    func piApiKey(provider: String) -> String? {
        guard let key = piAuth[provider]?["key"] as? String, !key.isEmpty else { return nil }
        return key
    }
}
