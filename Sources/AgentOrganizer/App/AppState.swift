import AppKit
import Foundation
import Observation

enum SidebarSelection: Hashable {
    case folder(Folder.ID)
    case agent(Agent.ID)
}

/// Top-level app state: owns the persisted `Store`, the tmux connection, the
/// terminal view cache, and current UI selection. `tmux` is optional because
/// tmux may not be installed — callers show onboarding instead of failing.
@MainActor
@Observable
final class AppState {
    let store = Store()
    private(set) var tmux: TmuxController?
    let cache = TerminalCache()

    var selection: SidebarSelection?
    /// Non-nil while the "new agent" popover should be shown for this folder
    /// (driven by either the sidebar's + button or the ⌘N menu command).
    var newAgentPopoverFolderID: Folder.ID?
    /// Folder pending removal confirmation (asks whether to kill its agents).
    var folderPendingRemoval: Folder?

    /// Refreshed by a periodic poll (see `startStatusPolling`), never by
    /// polling from a view's body — `has-session` is cheap but still a
    /// process spawn, so it happens on one timer, not once per rendered row.
    var agentStatuses: [Agent.ID: AgentStatus] = [:]
    private var statusTimer: Timer?

    init() {
        tmux = TmuxController()
        reconcileSessions()
    }

    func startStatusPolling() {
        statusTimer?.invalidate()
        refreshStatuses()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatuses() }
        }
    }

    func refreshStatuses() {
        guard let tmux else { return }
        let live = tmux.listSessions()
        for agent in store.agents {
            agentStatuses[agent.id] = live.contains(agent.tmuxSession) ? .running : .exited
        }
    }

    func recheckTmux() {
        tmux = TmuxController()
        if tmux != nil { reconcileSessions() }
    }

    var selectedFolder: Folder? {
        switch selection {
        case .folder(let id): return store.folder(id)
        case .agent(let id): return store.agents.first { $0.id == id }.flatMap { store.folder($0.folderID) }
        case nil: return nil
        }
    }

    var selectedAgent: Agent? {
        guard case .agent(let id) = selection else { return nil }
        return store.agents.first { $0.id == id }
    }

    /// Drop persisted agents whose tmux session no longer exists (e.g. the
    /// socket file was cleared out from under us) instead of showing a dead
    /// entry. Never kills a *live* session on launch.
    private func reconcileSessions() {
        guard let tmux else { return }
        let live = tmux.listSessions()
        let before = store.agents.count
        store.agents.removeAll { !live.contains($0.tmuxSession) }
        if store.agents.count != before { store.save() }
    }

    // MARK: Folders

    func presentAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose one or more project folders"
        guard panel.runModal() == .OK else { return }
        var lastAdded: Folder?
        for url in panel.urls {
            if let folder = store.addFolder(url: url) { lastAdded = folder }
        }
        if let lastAdded { selection = .folder(lastAdded.id) }
    }

    func requestRemoveFolder(_ folder: Folder) {
        if store.agents(in: folder.id).isEmpty {
            removeFolder(folder, killAgents: false)
        } else {
            folderPendingRemoval = folder
        }
    }

    func removeFolder(_ folder: Folder, killAgents: Bool) {
        for agent in store.agents(in: folder.id) {
            cache.discard(agent.id)
        }
        store.removeFolder(folder, killAgents: killAgents, tmux: tmux)
        if selectedFolder?.id == folder.id { selection = nil }
        folderPendingRemoval = nil
    }

    func rescan(_ folder: Folder) {
        store.rescan(folder)
    }

    // MARK: Agents

    var canCreateNewAgent: Bool { selectedFolder != nil }

    func requestNewAgentPopover() {
        guard let folder = selectedFolder else { return }
        newAgentPopoverFolderID = folder.id
    }

    func createAgent(folder: Folder, preset: AgentPreset, relativeCwd: String) {
        let session = "ao_\(Self.slug(folder.displayName))_\(UUID().uuidString.prefix(8).lowercased())"
        let agent = Agent(folderID: folder.id, relativeCwd: relativeCwd, presetID: preset.id, tmuxSession: session)
        let cwd = agent.resolvedCwd(folderPath: folder.path)
        tmux?.ensureSession(name: session, cwd: cwd, command: preset.command.isEmpty ? nil : preset.command)
        store.addAgent(agent)
        selection = .agent(agent.id)
        newAgentPopoverFolderID = nil
    }

    func killAgent(_ agent: Agent) {
        cache.discard(agent.id)
        store.removeAgent(agent, tmux: tmux)
        if selection == .agent(agent.id) {
            selection = store.folder(agent.folderID).map { .folder($0.id) }
        }
    }

    func restartAgent(_ agent: Agent) {
        let preset = store.preset(for: agent.presetID)
        let command = preset.resumeCommand ?? preset.command
        guard !command.isEmpty else { return }
        tmux?.sendKeys(to: agent.tmuxSession, text: command)
    }

    private static func slug(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = text.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped)
    }
}
