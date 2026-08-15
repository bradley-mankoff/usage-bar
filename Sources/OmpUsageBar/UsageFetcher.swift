import Foundation

enum FetchError: LocalizedError {
    case ompNotFound
    case exit(Int32, String)
    case decode(Error)
    case io(Error)

    var errorDescription: String? {
        switch self {
        case .ompNotFound:
            return "omp binary not found (set OMP_BIN to override)"
        case .exit(let code, let stderr):
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "omp usage failed (exit \(code))\(tail.isEmpty ? "" : ": \(tail)")"
        case .decode(let error):
            return "Could not parse omp usage output: \(error.localizedDescription)"
        case .io(let error):
            return error.localizedDescription
        }
    }
}

/// Runs `omp usage --json` synchronously and decodes the result.
/// The output is small (<16 KB) so a blocking read after exit is safe.
enum UsageFetcher {
    static let timeout: TimeInterval = 20

    static func resolveOmpPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            env["OMP_BIN"],
            "\(home)/.local/bin/omp",
            "/opt/homebrew/bin/omp",
            "/usr/local/bin/omp",
        ].compactMap { $0 }
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        return findInPath("omp")
    }

    static func fetchSync() throws -> UsageSnapshot {
        guard let omp = resolveOmpPath() else { throw FetchError.ompNotFound }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: omp)
        proc.arguments = ["usage", "--json"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw FetchError.io(error)
        }

        // Watchdog: never let a hung omp wedge the widget forever.
        let watchdog = DispatchWorkItem { [weak proc] in
            if proc?.isRunning == true { proc?.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        proc.waitUntilExit()
        watchdog.cancel()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard proc.terminationStatus == 0 else {
            throw FetchError.exit(proc.terminationStatus, err)
        }
        guard let data = out.data(using: .utf8) else {
            throw FetchError.decode(CocoaError(.coderReadCorrupt))
        }
        do {
            return try JSONDecoder().decode(UsageSnapshot.self, from: data)
        } catch {
            throw FetchError.decode(error)
        }
    }

    private static func findInPath(_ name: String) -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
