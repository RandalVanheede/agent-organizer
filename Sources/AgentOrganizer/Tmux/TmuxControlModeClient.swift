import Foundation

/// One long-lived `tmux -C` client attached to a hidden session on this
/// app's socket, used only to receive server-wide notifications:
///
///  - `%sessions-changed` fires whenever *any* session on the server is
///    created or destroyed, regardless of what this client is attached to
///    — confirmed empirically, not documented explicitly by tmux. This is
///    what makes agent death/creation detection event-driven instead of
///    polled.
///  - `%window-renamed` / `%unlinked-window-renamed` fire for *any* window
///    renaming itself (tools like Claude Code set their pane title this
///    way), again regardless of attachment. Only the window id is given,
///    so a session-name map is rebuilt after every sessions-changed event.
///
/// This client never sends commands and never renders a pane — SwiftTerm's
/// own per-agent `tmux attach` clients do that. If tmux isn't installed, or
/// the control client fails to start, callers simply keep working off the
/// slower fallback poll — this is a latency optimization, not a dependency.
@MainActor
final class TmuxControlModeClient {
    /// Sessions named with this prefix are internal plumbing (this hidden
    /// control-mode target) and must never be shown to the user as agents
    /// or orphans.
    static let hiddenSessionName = "__ao_control"

    private let process = Process()
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private weak var tmux: TmuxController?
    private var started = false

    /// window id ("@N") -> session name
    private var windowToSession: [String: String] = [:]

    var onSessionsChanged: (() -> Void)?
    var onTitleChanged: ((_ sessionName: String, _ title: String) -> Void)?

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

        // A pipe we keep open for the process lifetime: if stdin ever hits
        // EOF, tmux's control client treats that as a detach request.
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
        } catch {
            started = false
        }
    }

    func stop() {
        guard started else { return }
        started = false
        if let stdinHandle {
            try? stdinHandle.close()
        }
        if process.isRunning {
            process.terminate()
        }
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
}
