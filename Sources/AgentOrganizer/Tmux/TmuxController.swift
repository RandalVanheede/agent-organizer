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
        // Not `waitUntilExit()`: it spins the run loop, which re-enters
        // SwiftUI when called from inside a view update (crashed the app).
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        done.wait()
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

    /// Kills whatever is running in the session's pane (the shell and its
    /// children) and respawns a fresh login shell in `cwd`, then types
    /// `command` into it. Used by "Restart" so e.g. `claude --continue` is
    /// never typed *into* a still-running claude.
    func respawn(session: String, cwd: URL, command: String?) {
        run(["respawn-pane", "-k", "-c", cwd.path, "-t", session])
        if let command, !command.isEmpty {
            sendKeys(to: session, text: command)
        }
    }

    func killSession(_ name: String) {
        run(["kill-session", "-t", name])
    }

    /// Window id ("@N") -> owning session name, across the whole server.
    /// Used to resolve `%window-renamed`/`%unlinked-window-renamed` control
    /// mode events (which only carry a window id) back to a session.
    func windowSessionMap() -> [String: String] {
        let (status, output) = run(["list-windows", "-a", "-F", "#{window_id} #{session_name}"])
        guard status == 0 else { return [:] }
        var map: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            map[String(parts[0])] = String(parts[1])
        }
        return map
    }

    /// Session owning a pane id such as "%7" (a hook's `TMUX_PANE`).
    func sessionName(forPane paneID: String) -> String? {
        let (status, output) = run(["display-message", "-p", "-t", paneID, "#{session_name}"])
        guard status == 0 else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Session name → pane PID for every pane on this socket.
    func panePids() -> [String: pid_t] {
        let (status, output) = run(["list-panes", "-a", "-F", "#{session_name} #{pane_pid}"])
        guard status == 0 else { return [:] }
        var map: [String: pid_t] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let pid = pid_t(parts[1]) else { continue }
            map[String(parts[0])] = pid
        }
        return map
    }

    /// The working directory a session's active pane currently sits in.
    /// Used to guess which folder an untracked ("orphan") session belongs to.
    func paneCurrentPath(session: String) -> String? {
        let (status, output) = run(["display-message", "-p", "-t", session, "#{pane_current_path}"])
        guard status == 0 else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
