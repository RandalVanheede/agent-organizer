import AppKit
import Foundation
import Observation

/// Top-level app state: owns the persisted `Store`, the tmux connection, the
/// terminal view cache, and current UI selection. `tmux` is optional because
/// tmux may not be installed — callers show onboarding instead of failing.
/// One tmux session that exists on our socket but isn't tracked as an
/// agent — typically left behind by "Remove Folder, Keep Agents Running".
/// Surfaced rather than hidden, so nothing running is ever silently lost.
struct OrphanSession: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var cwd: String?
    var matchingFolderID: Folder.ID?
}

@MainActor
@Observable
final class AppState {
    let store = Store()
    private(set) var tmux: TmuxController?
    let cache = TerminalCache()
    private let controlClient = TmuxControlModeClient()
    private let watcher = FolderWatcher()

    /// Sidebar selection: folders behave like vertical tabs.
    private(set) var selectedFolderID: Folder.ID?
    /// Which agent tab is active inside each folder (horizontal tabs on
    /// the canvas). Missing entry = first agent in that folder.
    private(set) var activeAgentByFolder: [Folder.ID: Agent.ID] = [:]
    /// Non-nil while the "new agent" popover should be shown for this folder
    /// (driven by either the sidebar's + button or the ⌘N menu command).
    var newAgentPopoverFolderID: Folder.ID?
    /// Folder pending removal confirmation (asks whether to kill its agents).
    var folderPendingRemoval: Folder?
    /// A second agent shown side-by-side with the selected one, so two
    /// agents in the same folder can be watched/worked at once. Cleared
    /// whenever it stops making sense (killed, or selection moves to a
    /// different folder) rather than left pointing at something stale.
    var splitAgentID: Agent.ID?

    /// Kept fresh primarily by tmux control-mode's `%sessions-changed`
    /// event (near-instant); `startStatusPolling` also runs a slow fallback
    /// poll in case the control connection ever drops silently.
    var agentStatuses: [Agent.ID: AgentStatus] = [:]
    /// tmux session name -> latest live pane title (from control mode window
    /// renames), overridden by a user-set `Agent.title` when present.
    var liveTitles: [String: String] = [:]
    var orphanSessions: [OrphanSession] = []
    private var statusTimer: Timer?

    init() {
        tmux = TmuxController()
        reconcileSessions()
        wireControlClient()
        for folder in store.folders { watcher.watch(folder) }
        watcher.onChange = { [weak self] id in self?.handleFolderChanged(id) }
        restoreUISelection()
    }

    private func restoreUISelection() {
        if let id = store.lastSelectedFolderID, store.folder(id) != nil {
            selectedFolderID = id
        }
        for (f, a) in store.activeAgentByFolder {
            if let fid = UUID(uuidString: f), let aid = UUID(uuidString: a),
               store.folder(fid) != nil, store.agents.contains(where: { $0.id == aid }) {
                activeAgentByFolder[fid] = aid
            }
        }
    }

    private func persistUISelection() {
        var map: [String: String] = [:]
        for (f, a) in activeAgentByFolder { map[f.uuidString] = a.uuidString }
        store.setUISelection(folderID: selectedFolderID, activeAgentByFolder: map)
    }

    func selectFolder(_ id: Folder.ID?) {
        selectedFolderID = id
        splitAgentID = nil
        persistUISelection()
    }

    func selectAgent(_ agent: Agent) {
        selectedFolderID = agent.folderID
        activeAgentByFolder[agent.folderID] = agent.id
        if splitAgentID == agent.id { splitAgentID = nil }
        persistUISelection()
    }

    private func wireControlClient() {
        guard let tmux else { return }
        controlClient.start(tmux: tmux)
        controlClient.onSessionsChanged = { [weak self] in
            self?.refreshStatuses()
        }
        controlClient.onTitleChanged = { [weak self] sessionName, title in
            self?.liveTitles[sessionName] = title
        }
    }

    func startStatusPolling() {
        statusTimer?.invalidate()
        refreshStatuses()
        // Slow safety net only — the control-mode client is the primary,
        // near-instant path. If it silently dies this still catches up.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatuses() }
        }
    }

    func refreshStatuses() {
        guard let tmux else { return }
        let live = tmux.listSessions()
        for agent in store.agents {
            agentStatuses[agent.id] = live.contains(agent.tmuxSession) ? .running : .exited
        }
        refreshOrphans(live: live)
    }

    func liveTitle(for agent: Agent) -> String? {
        liveTitles[agent.tmuxSession]
    }

    private func refreshOrphans(live: Set<String>) {
        guard let tmux else { orphanSessions = []; return }
        let known = Set(store.agents.map { $0.tmuxSession })
        let untracked = live.filter { !$0.hasPrefix("__ao_") && !known.contains($0) }
        orphanSessions = untracked.sorted().map { name in
            let cwd = tmux.paneCurrentPath(session: name)
            let match = cwd.flatMap { path in
                store.folders.first { path.hasPrefix($0.path.path) }
            }
            return OrphanSession(name: name, cwd: cwd, matchingFolderID: match?.id)
        }
    }

    func adopt(_ orphan: OrphanSession, into folder: Folder) {
        var relativeCwd = ""
        if let cwd = orphan.cwd {
            let root = folder.path.path
            if cwd.hasPrefix(root) {
                relativeCwd = String(cwd.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }
        let agent = Agent(folderID: folder.id, relativeCwd: relativeCwd, presetID: AgentPreset.shell.id, tmuxSession: orphan.name)
        store.addAgent(agent)
        refreshStatuses()
    }

    func killOrphan(_ orphan: OrphanSession) {
        tmux?.killSession(orphan.name)
        refreshStatuses()
    }

    func recheckTmux() {
        tmux = TmuxController()
        if tmux != nil {
            reconcileSessions()
            wireControlClient()
        }
    }

    var selectedFolder: Folder? {
        selectedFolderID.flatMap { store.folder($0) }
    }

    /// The active tab of the selected folder, falling back to its first
    /// agent when nothing (or something since killed) is recorded.
    var selectedAgent: Agent? {
        guard let folder = selectedFolder else { return nil }
        let agents = store.agents(in: folder.id)
        if let id = activeAgentByFolder[folder.id], let agent = agents.first(where: { $0.id == id }) {
            return agent
        }
        return agents.first
    }

    /// Only valid alongside a primary agent in the *same* folder — a stale
    /// id (killed, or left over from a different folder) simply renders
    /// nothing rather than needing to be proactively cleared everywhere.
    var splitAgent: Agent? {
        guard let splitAgentID, let primary = selectedAgent,
              let candidate = store.agents.first(where: { $0.id == splitAgentID }),
              candidate.folderID == primary.folderID, candidate.id != primary.id
        else { return nil }
        return candidate
    }

    func toggleSplit(with agent: Agent) {
        splitAgentID = (splitAgentID == agent.id) ? nil : agent.id
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
            if let folder = store.addFolder(url: url) {
                lastAdded = folder
                watcher.watch(folder)
            }
        }
        if let lastAdded { selectFolder(lastAdded.id) }
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
        watcher.stopWatching(folder.id)
        store.removeFolder(folder, killAgents: killAgents, tmux: tmux)
        activeAgentByFolder.removeValue(forKey: folder.id)
        if selectedFolderID == folder.id { selectedFolderID = nil }
        folderPendingRemoval = nil
        persistUISelection()
    }

    func rescan(_ folder: Folder) {
        store.rescan(folder)
        if let updated = store.folder(folder.id) { watcher.watch(updated) }
    }

    /// Called when the filesystem watcher fires for a folder: re-scan it
    /// (branch/sub-repo set may have changed) and re-arm the watch, since
    /// the set of `.git/HEAD` paths worth watching may itself have changed.
    private func handleFolderChanged(_ id: Folder.ID) {
        guard let folder = store.folder(id) else {
            watcher.stopWatching(id)
            return
        }
        store.rescan(folder)
        if let updated = store.folder(id) { watcher.watch(updated) }
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
        selectAgent(agent)
        newAgentPopoverFolderID = nil
    }

    func killAgent(_ agent: Agent) {
        cache.discard(agent.id)
        store.removeAgent(agent, tmux: tmux)
        if activeAgentByFolder[agent.folderID] == agent.id {
            activeAgentByFolder.removeValue(forKey: agent.folderID)
        }
        if splitAgentID == agent.id { splitAgentID = nil }
        persistUISelection()
    }

    func restartAgent(_ agent: Agent) {
        let preset = store.preset(for: agent.presetID)
        let command = preset.resumeCommand ?? preset.command
        guard !command.isEmpty else { return }
        tmux?.sendKeys(to: agent.tmuxSession, text: command)
    }

    func moveAgents(in folderID: Folder.ID, fromOffsets source: IndexSet, toOffset destination: Int) {
        store.moveAgents(in: folderID, fromOffsets: source, toOffset: destination)
    }

    /// Shift one tab left (-1) or right (+1) within its folder.
    func moveAgent(_ agent: Agent, by offset: Int) {
        let agents = store.agents(in: agent.folderID)
        guard let idx = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        let target = idx + offset
        guard target >= 0, target < agents.count else { return }
        // IndexSet/toOffset semantics: moving right by one needs destination idx+2.
        let destination = offset > 0 ? target + 1 : target
        store.moveAgents(in: agent.folderID, fromOffsets: IndexSet(integer: idx), toOffset: destination)
    }

    func canMoveAgent(_ agent: Agent, by offset: Int) -> Bool {
        let agents = store.agents(in: agent.folderID)
        guard let idx = agents.firstIndex(where: { $0.id == agent.id }) else { return false }
        let target = idx + offset
        return target >= 0 && target < agents.count
    }

    /// Any agent in this folder whose tmux session is gone — used for the
    /// sidebar's attention dot now that agents aren't listed there.
    func folderHasExitedAgent(_ folderID: Folder.ID) -> Bool {
        store.agents(in: folderID).contains { agentStatuses[$0.id] == .exited }
    }

    func setTerminalFontSize(_ size: Double) {
        store.setTerminalFontSize(size)
        cache.applyFontSize(store.terminalFontSize)
    }

    private static func slug(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = text.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped)
    }
}
