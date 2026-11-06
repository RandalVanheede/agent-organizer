import Foundation

/// Live facts about one session's active pane, from the control-mode
/// format subscription (see `TmuxControlModeClient`).
struct PaneSnapshot: Equatable {
    let paneID: String          // "%12" — what `TMUX_PANE` is inside the pane
    let command: String         // `#{pane_current_command}`, e.g. "zsh", "node"
    let activity: TimeInterval  // `#{window_activity}`, unix seconds
    let title: String           // `#{pane_title}` (OSC 0/2), "" when still tmux's default (host name)
}

/// One long-lived `tmux -C` client attached to a hidden session on this
/// app's socket, used only to receive server-wide notifications:
///
///  - `%sessions-changed` fires whenever *any* session on the server is
///    created or destroyed, regardless of what this client is attached to
///    — confirmed empirically. Event-driven agent death/creation detection.
///  - `%window-renamed` / `%unlinked-window-renamed` fire for *any* window
///    renaming itself (tools like Claude Code set their pane title this
///    way). Only the window id is given, so a session-name map is rebuilt
///    after every sessions-changed event.
///  - A **format subscription** (`refresh-client -B`) over `#{S:...}` — a
///    loop across *all* sessions — reports each session's active pane id,
///    current command and last-activity time. tmux re-evaluates it at most
///    once a second and only sends `%subscription-changed` when the value
///    differs, so this replaces polling for status entirely.
///
/// This client never renders a pane — SwiftTerm's own per-agent `tmux
/// attach` clients do that. If it fails to start, callers keep working off
/// the slow fallback poll; this is a latency optimization, not a dependency.
@MainActor
final class TmuxControlModeClient {
    /// Sessions named with this prefix are internal plumbing and must never
    /// be shown to the user as agents or orphans.
    static let hiddenSessionName = "__ao_control"
    private static let subscriptionName = "aostatus"

    private let process = Process()
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private weak var tmux: TmuxController?
    private var started = false

    /// window id ("@N") -> session name
    private var windowToSession: [String: String] = [:]
    /// session name -> latest pane snapshot
    private(set) var panes: [String: PaneSnapshot] = [:]

    var onSessionsChanged: (() -> Void)?
    var onTitleChanged: ((_ sessionName: String, _ title: String) -> Void)?
    var onPanesChanged: (() -> Void)?

    var isRunning: Bool { started && process.isRunning }

    func start(tmux: TmuxController) {
        guard !started else { return }
        started = true
        self.tmux = tmux

        tmux.ensureSession(name: Self.hiddenSessionName, cwd: FileManager.default.temporaryDirectory, command: nil)

        var args = ["-S", tmux.socketPath]
        if let conf = tmux.confPath { args += ["-f", conf] }
        args += ["-C", "attach-session", "-t", Self.hiddenSessionName]

        process.executableURL = URL(fileURLWithPath: tmux.tmuxBinary)
        process.arguments = args

        // Kept open for the process lifetime: EOF on stdin = detach request.
        let stdinPipe = Pipe()
        stdinHandle = stdinPipe.fileHandleForWriting
        process.standardInput = stdinPipe

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }

        do {
            try process.run()
            windowToSession = tmux.windowSessionMap()
            subscribe()
        } catch {
            started = false
        }
    }

    private func subscribe() {
        // One string for all sessions: name|paneID|command|activity|title;...
        // Title last (may contain '|'). A ';' in it just truncates the title
        // (the leftover fragment fails the field-count check); `s/;/…/` can't
        // be used, ';' separates format modifiers.
        let title = "#{?#{==:#{pane_title},#{host}},,#{pane_title}}"
        let format = "#{S:#{session_name}|#{pane_id}|#{pane_current_command}|#{window_activity}|\(title);}"
        send("refresh-client -B \(Self.subscriptionName)::\"\(format)\"")
    }

    private func send(_ command: String) {
        guard let stdinHandle, let data = (command + "\n").data(using: .utf8) else { return }
        try? stdinHandle.write(contentsOf: data)
    }

    func stop() {
        guard started else { return }
        started = false
        try? stdinHandle?.close()
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            handle(line: line)
        }
    }

    private func handle(line: String) {
        if line.hasPrefix("%sessions-changed") {
            if let tmux { windowToSession = tmux.windowSessionMap() }
            onSessionsChanged?()
        } else if line.hasPrefix("%subscription-changed \(Self.subscriptionName) ") {
            // "%subscription-changed <name> $sid @wid %pid ... : <payload>"
            guard let sep = line.range(of: " : ") else { return }
            parseSubscription(String(line[sep.upperBound...]))
        } else if line.hasPrefix("%window-renamed") || line.hasPrefix("%unlinked-window-renamed") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3 else { return }
            let windowID = String(parts[1])
            let title = String(parts[2])
            if let session = windowToSession[windowID], session != Self.hiddenSessionName {
                onTitleChanged?(session, title)
            }
        } else if line.hasPrefix("%window-close") || line.hasPrefix("%unlinked-window-close") {
            let parts = line.split(separator: " ")
            if parts.count >= 2 { windowToSession.removeValue(forKey: String(parts[1])) }
        }
    }

    private func parseSubscription(_ payload: String) {
        var next: [String: PaneSnapshot] = [:]
        var seenSessions: [String: Int] = [:], seenPanes: [String: Int] = [:]
        for entry in payload.split(separator: ";") {
            let f = entry.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            guard f.count == 5, let activity = TimeInterval(f[3]) else { continue }
            let session = String(f[0])
            seenSessions[session, default: 0] += 1
            seenPanes[String(f[1]), default: 0] += 1
            guard session != Self.hiddenSessionName else { continue }
            next[session] = PaneSnapshot(paneID: String(f[1]), command: String(f[2]), activity: activity, title: String(f[4]))
        }
        // Titles are pane-controlled (OSC 2) and can't be escaped here, so a
        // title like "x;ao_other|%5|zsh|0|" forges entries. tmux lists each
        // session and pane once: drop anything that shows up twice.
        next = next.filter { seenSessions[$0.key] == 1 && seenPanes[$0.value.paneID] == 1 }
        if next != panes {
            panes = next
            onPanesChanged?()
        }
    }

    /// Resolve a `TMUX_PANE` value (e.g. from a Claude Code hook) to its session.
    func sessionName(forPaneID paneID: String) -> String? {
        panes.first { $0.value.paneID == paneID }?.key
    }
}
