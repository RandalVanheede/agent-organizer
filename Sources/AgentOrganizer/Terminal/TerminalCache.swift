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
    private var views: [Agent.ID: AOTerminalView] = [:]
    private var delegates: [Agent.ID: TerminalAttachDelegate] = [:]
    /// Source of the terminal key bindings; set by `AppState`.
    weak var store: Store?

    func view(for agent: Agent, cwd: URL, tmux: TmuxController, fontSize: Double) -> AOTerminalView {
        if let existing = views[agent.id] {
            return existing
        }

        let view = AOTerminalView(frame: .zero)
        view.store = store
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let delegate = TerminalAttachDelegate()
        view.processDelegate = delegate
        delegates[agent.id] = delegate

        // Never create the session here: this runs inside a SwiftUI update,
        // and a stale agent (just killed) would resurrect as an orphan.
        // Sessions are created by `AppState.createAgent` only.
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

/// Terminal.app-style word/line navigation (bindings from
/// `ShortcutAction.terminalActions`). SwiftTerm's own keyDown can't be
/// overridden (not `open`), but AppKit offers every key event to
/// `performKeyEquivalent` first, so intercept them there.
final class AOTerminalView: LocalProcessTerminalView {
    weak var store: Store?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let store,
              let bytes = ShortcutAction.terminalActions
                .first(where: { store.shortcut($0)?.matches(event) == true })?.terminalBytes
        else { return super.performKeyEquivalent(with: event) }
        send(bytes)
        return true
    }
}
