import Foundation

/// Agents in a remote folder (HBY-13). The agent is still a *local* tmux
/// session (so status, persistence and the terminal cache work unchanged),
/// but what runs in it is `ssh -t <host>` attached to a same-named tmux
/// session on the remote's own `-L agent-organizer` server. That remote
/// session is where the tool really lives, so it survives the laptop
/// sleeping or the network dropping; the local side reconnects on its own.
enum RemoteSession {
    /// Remote tmux server name (`tmux -L`), kept apart from the user's own.
    private static let tmux = "tmux -L agent-organizer"

    /// The local pane's command (run by tmux via the user's shell). `sh -c`
    /// so the reconnect loop works whatever that shell is (fish etc.); a
    /// login shell takes over afterwards so the tab stays usable.
    static func launchCommand(host: String, session: String, cwd: String, command: String?) -> String {
        var create = "\(tmux) new-session -d -s \(session) -c \(quote(cwd))"
        if let command, !command.isEmpty {
            create += " && \(typeWhenReady(session: session, command: command))"
        }
        // Re-running `create` on reconnect is harmless: new-session fails
        // for an existing session, so send-keys is skipped.
        return wrap(host: host, session: session, firstConnect: create, reconnect: create)
    }

    /// Restart: kill whatever runs in the remote pane, start `command` fresh.
    static func restartCommand(host: String, session: String, cwd: String, command: String?) -> String {
        var respawn = "\(tmux) respawn-pane -k -c \(quote(cwd)) -t \(session)"
        if let command, !command.isEmpty {
            respawn += " && \(typeWhenReady(session: session, command: command))"
        }
        return wrap(host: host, session: session, firstConnect: respawn, reconnect: nil)
    }

    /// Keys typed before the shell's line editor is up can lose their Enter
    /// (seen locally), so wait until the pane shows anything (the prompt;
    /// the pane starts / respawns blank), max ~5 s, plus a short grace.
    /// `sh -c`: the remote login shell running this may be fish.
    private static func typeWhenReady(session: String, command: String) -> String {
        let script = "i=0; while [ $i -lt 50 ] && [ -z \"$(\(tmux) capture-pane -p -t \(session) | tr -d '[:space:]')\" ]; do sleep 0.1; i=$((i+1)); done; sleep 0.3; \(tmux) send-keys -t \(session) -- \(quote(command)) Enter"
        return "sh -c \(quote(script))"
    }

    /// Fire-and-forget: killing the local session only drops the ssh link,
    /// the remote session must be killed explicitly. Needs key auth
    /// (BatchMode); otherwise the remote session lingers and is logged.
    static func kill(host: String, session: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "\(tmux) kill-session -t \(session)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { p in
            if p.terminationStatus != 0 {
                HookLog.write("remote kill \(session) on \(host) failed (status \(p.terminationStatus))")
            }
        }
        try? process.run()
    }

    /// First connect runs `firstConnect` (create / respawn), then attaches.
    /// ssh exits 255 only on connection errors: retry (`reconnect`, then
    /// attach). A normal exit (remote session ended, user detached) stops.
    private static func wrap(host: String, session: String, firstConnect: String, reconnect: String?) -> String {
        // Mirrors Resources/tmux.conf: clipboard + passthrough so Claude's own
        // (OSC 52) copy reaches the Mac; escape-time so Esc isn't delayed.
        let options = ["status off", "mouse on", "set-clipboard on", "allow-passthrough on", "escape-time 0", "focus-events on"]
            .map { "set -g \($0)" }.joined(separator: " ';' ")
        var attach = "\(tmux) \(options); exec \(tmux) attach -t \(session)"
        let first = "\(firstConnect); \(attach)"
        if let reconnect { attach = "\(reconnect); \(attach)" }
        let script = """
        ssh -t \(quote(host)) \(quote(first)); \
        while [ $? -eq 255 ]; do echo 'Connection lost, reconnecting in 3s…'; sleep 3; \
        ssh -t \(quote(host)) \(quote(attach)); done
        """
        return "sh -c \(quote(script)); exec \"$SHELL\" -l"
    }

    /// POSIX single-quote; the same escape also works in fish.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
