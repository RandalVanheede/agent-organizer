import Foundation

/// Thin wrapper over one-shot `tmux` invocations against this app's own
/// socket. The tmux *server* is a separate long-lived process tmux itself
/// spawns on first use — it is not something this app manages directly, and
/// it survives this app quitting.
///
/// Immutable, so it is `Sendable`: periodic queries run on background tasks
/// (each call blocks its caller until tmux exits).
final class TmuxController: Sendable {
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
        var fullArgs = ["-S", socketPath]
        if let confPath {
            fullArgs += ["-f", confPath]
        }
        return Self.exec(tmuxBinary, fullArgs + args)
    }

    @discardableResult
    private static func exec(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

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
        // A hung server must not park the caller's thread forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if process.isRunning { process.terminate() }
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// A server whose last session died while a client stayed attached (our
    /// control client, orphaned when an earlier app run died) waits for that
    /// client forever and drops every new connection: "server exited
    /// unexpectedly". It has no sessions left, so kill every process on our
    /// socket; the next tmux command starts a fresh server. Checked twice so
    /// a server that is merely restarting is left alone.
    @discardableResult
    func recoverIfWedged() -> Bool {
        func wedged() -> Bool {
            let (status, output) = run(["list-sessions"])
            return status != 0 && output.contains("server exited unexpectedly")
        }
        guard wedged() else { return false }
        Thread.sleep(forTimeInterval: 0.3)
        guard wedged() else { return false }
        Self.exec("/usr/bin/pkill", ["-f", "--", "-S " + NSRegularExpression.escapedPattern(for: socketPath) + "( |$)"])
        Thread.sleep(forTimeInterval: 0.3)
        return true
    }

    /// Terminates control-mode clients on `session` whose app is gone (they
    /// were reparented to launchd) — left behind when an earlier run died.
    /// A live app instance's client is left alone.
    func killOrphanedControlClients(session: String) {
        let (status, output) = run(["list-clients", "-t", session, "-F", "#{client_pid} #{client_control_mode}"])
        guard status == 0 else { return }
        for line in output.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count == 2, f[1] == "1", let pid = pid_t(f[0]), Self.parentPID(of: pid) == 1 else { continue }
            kill(pid, SIGTERM)
        }
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
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
    /// `paneCommand` replaces the login shell as the pane's process instead of
    /// being typed into it (typed text can lose its Enter while a slow shell
    /// starts up).
    func ensureSession(name: String, cwd: URL, command: String?, paneCommand: String? = nil) -> Bool {
        if sessionExists(name) { return true }
        let (status, _) = run(["new-session", "-d", "-s", name, "-c", cwd.path, "-x", "200", "-y", "50"] + (paneCommand.map { [$0] } ?? []))
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
    func respawn(session: String, cwd: URL, command: String?, paneCommand: String? = nil) {
        run(["respawn-pane", "-k", "-c", cwd.path, "-t", session] + (paneCommand.map { [$0] } ?? []))
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

    /// The working directory a session's active pane currently sits in.
    /// Used to guess which folder an untracked ("orphan") session belongs to.
    func paneCurrentPath(session: String) -> String? {
        let (status, output) = run(["display-message", "-p", "-t", session, "#{pane_current_path}"])
        guard status == 0 else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
