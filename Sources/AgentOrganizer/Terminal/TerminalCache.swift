import AppKit
import SwiftTerm

/// Holds one live `LocalProcessTerminalView` per agent for the lifetime of
/// the app run. Views are created lazily on first attach and are never
/// evicted while the agent still exists — switching folders/agents in the
/// sidebar must not lose scrollback or detach the underlying tmux client.
///
/// Quitting the app tears these views (and their `tmux attach` child
/// processes) down, but the tmux *server* and its sessions live on outside
/// this process, so nothing the user was running is lost.
@MainActor
final class TerminalCache {
    private var views: [Agent.ID: LocalProcessTerminalView] = [:]
    private var delegates: [Agent.ID: TerminalAttachDelegate] = [:]

    func view(for agent: Agent, cwd: URL, tmux: TmuxController, fontSize: Double) -> LocalProcessTerminalView {
        if let existing = views[agent.id] {
            return existing
        }

        let view = LocalProcessTerminalView(frame: .zero)
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let delegate = TerminalAttachDelegate()
        view.processDelegate = delegate
        delegates[agent.id] = delegate

        tmux.ensureSession(name: agent.tmuxSession, cwd: cwd, command: nil)

        let args = ["-S", tmux.socketPath] + (tmux.confPath.map { ["-f", $0] } ?? []) + ["attach-session", "-t", agent.tmuxSession]
        view.startProcess(executable: tmux.tmuxBinary, args: args)

        views[agent.id] = view
        return view
    }

    /// Applies a new font size to every currently-live terminal view. Called
    /// when the user changes the preference — new agents pick it up via
    /// `view(for:...)`'s initial set, existing ones need this explicit push.
    func applyFontSize(_ size: Double) {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        for view in views.values {
            view.font = font
        }
    }

    func hasView(for agentID: Agent.ID) -> Bool {
        views[agentID] != nil
    }

    func exitedAgents() -> Set<Agent.ID> {
        Set(delegates.filter { $0.value.terminated }.keys)
    }

    /// Only called when the user explicitly kills/removes an agent.
    func discard(_ agentID: Agent.ID) {
        views.removeValue(forKey: agentID)
        delegates.removeValue(forKey: agentID)
    }
}

/// Tracks whether the attach client (and therefore, presumably, the tmux
/// session) has died, without doing anything else — no auto-restart, no hiding.
final class TerminalAttachDelegate: LocalProcessTerminalViewDelegate {
    private(set) var terminated = false

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        terminated = true
    }
}
