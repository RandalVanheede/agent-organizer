import Foundation

/// Thin wrapper over one-shot `tmux` invocations against this app's own
/// socket. The tmux *server* is a separate long-lived process tmux itself
/// spawns on first use — it is not something this app manages directly, and
/// it survives this app quitting.
final class TmuxController {
    let socketPath: String
    let tmuxBinary: String
    let confPath: String?

    /// nil when tmux isn't installed / can't be located — callers show onboarding.
    init?() {
        guard let binary = TmuxPaths.resolveTmuxBinary() else { return nil }
        self.tmuxBinary = binary
        self.socketPath = TmuxPaths.socketPath()
        self.confPath = Bundle.main.path(forResource: "tmux", ofType: "conf")
    }

    @discardableResult
    private func run(_ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxBinary)
        var fullArgs = ["-S", socketPath]
        if let confPath {
            fullArgs += ["-f", confPath]
        }
        fullArgs += args
        process.arguments = fullArgs

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        process.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func sessionExists(_ name: String) -> Bool {
        run(["has-session", "-t", name]).status == 0
    }

    func listSessions() -> Set<String> {
        let (status, output) = run(["list-sessions", "-F", "#{session_name}"])
        guard status == 0 else { return [] }
        return Set(output.split(separator: "\n").map(String.init))
    }

    /// Creates the session detached if it doesn't already exist, then types
    /// the launch command into it. Safe to call for an already-running
    /// session (no-op) so reconciliation on launch can call this freely.
    @discardableResult
    func ensureSession(name: String, cwd: URL, command: String?) -> Bool {
        if sessionExists(name) { return true }
        let (status, _) = run(["new-session", "-d", "-s", name, "-c", cwd.path, "-x", "200", "-y", "50"])
        guard status == 0 else { return false }
        if let command, !command.isEmpty {
            sendKeys(to: name, text: command)
        }
        return true
    }

    func sendKeys(to session: String, text: String) {
        run(["send-keys", "-t", session, "--", text, "Enter"])
    }

    func killSession(_ name: String) {
        run(["kill-session", "-t", name])
    }
}
