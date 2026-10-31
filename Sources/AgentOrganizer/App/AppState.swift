import AppKit
import Foundation
import Observation
@preconcurrency import UserNotifications

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
    let resourceMonitor = ResourceMonitor()
    private let controlClient = TmuxControlModeClient()
    private let watcher = FolderWatcher()
    private let hookWatcher = HookEventWatcher()

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
    /// Agents a Claude Code hook flagged as needing the user (Notification /
    /// Stop). Cleared when the tab is viewed. Drives the dock badge.
    var attention: Set<Agent.ID> = []
    private var statusTimer: Timer?
    private var recomputeTimer: Timer?
    /// Shells: a pane running only one of these is "idle".
    private static let shellCommands: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "ksh", "nu", "login", "-zsh", "-bash"]
    /// Output within this window counts as "running".
    private static let runningWindow: TimeInterval = 2.5
    /// A tool that was running and has been quiet this long is assumed to be
    /// waiting for the user (used for tools without hooks, e.g. OpenCode).
    private static let quietBeforeDing: TimeInterval = 4.0
    /// Per-agent: when it last went quiet, and whether this quiet episode
    /// already dinged. Reset whenever the agent produces output again.
    private var quietSince: [Agent.ID: TimeInterval] = [:]
    private var dingedThisEpisode: Set<Agent.ID> = []
    /// Agents with a hook event in the last few seconds — hooks are the
    /// authoritative signal, so the activity heuristic stays quiet for them.
    private var lastHookAt: [Agent.ID: TimeInterval] = [:]

    init() {
        cache.store = store
        tmux = TmuxController()
        reconcileSessions()
        wireControlClient()
        for folder in store.folders { watcher.watch(folder) }
        watcher.onChange = { [weak self] id in self?.handleFolderChanged(id) }
        hookWatcher.onEvent = { [weak self] event in self?.handleHookEvent(event) }
        hookWatcher.start()
        restoreUISelection()
    }

    // MARK: Claude Code hooks → attention + system notifications

    private func handleHookEvent(_ event: HookEventWatcher.Event) {
        let session = sessionName(forPaneID: event.pane) ?? tmux?.sessionName(forPane: event.pane)
        guard let session, let agent = store.agents.first(where: { $0.tmuxSession == session }) else {
            HookLog.write("event \(event.name) pane=\(event.pane) -> no agent (session=\(session ?? "nil"))")
            return
        }
        HookLog.write("event \(event.name) pane=\(event.pane) -> \(session)")
        lastHookAt[agent.id] = Date().timeIntervalSince1970

        switch event.name {
        case "UserPromptSubmit":
            clearAttention(agent.id)
        case "Notification", "Stop":
            // The user is actively watching this exact tab: no sound, no
            // toast/notification, no dot. Anything else - other tab, other
            // app, app hidden/minimized - gets the full treatment.
            guard !isBeingWatched(agent.id) else { break }
            flagAttention(agent.id)
            playAttentionSound()
            let folderName = store.folder(agent.folderID)?.displayName ?? ""
            let title = agent.title ?? liveTitle(for: agent) ?? store.preset(for: agent.presetID).name
            postNotification(
                agentID: agent.id,
                title: folderName.isEmpty ? title : "\(title) — \(folderName)",
                body: event.message ?? (event.name == "Stop" ? "Finished — waiting for your next prompt." : "Needs your input.")
            )
        default:
            break
        }
    }

    /// System notification when macOS allows it; otherwise (locally built,
    /// non-Apple-signed app → "Notifications are not allowed") an in-app
    /// floating toast. Dock badge + bounce happen regardless.
    private func postNotification(agentID: Agent.ID, title: String, body: String) {
        if let app = NSApp, !app.isActive {
            app.requestUserAttention(.informationalRequest)
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in
                if allowed {
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = body
                    content.sound = nil // playAttentionSound() already rang
                    content.userInfo = ["agentID": agentID.uuidString]
                    let request = UNNotificationRequest(identifier: "agent-\(agentID.uuidString)", content: content, trigger: nil)
                    center.add(request) { error in
                        if let error { HookLog.write("system notification failed: \(error.localizedDescription)") }
                    }
                    HookLog.write("system notification: \"\(title)\"")
                } else {
                    HookLog.write("toast (system notifications not allowed, status=\(settings.authorizationStatus.rawValue)): \"\(title)\"")
                    ToastCenter.shared.show(title: title, body: body) { [weak self] in
                        self?.selectAgent(id: agentID)
                    }
                }
            }
        }
    }

    /// True when the app is frontmost, its main window (not e.g. the
    /// Preferences panel) is key, and this agent's tab is the one showing —
    /// i.e. the user is actively watching it right now.
    private func isBeingWatched(_ agentID: Agent.ID) -> Bool {
        guard let app = NSApp else { return false }
        return app.isActive && (app.keyWindow?.isMainWindow ?? false) && selectedAgent?.id == agentID
    }

    /// From a notification click: jump to that agent.
    func selectAgent(id: Agent.ID) {
        guard let agent = store.agents.first(where: { $0.id == id }) else { return }
        selectAgent(agent)
        NSApp?.activate(ignoringOtherApps: true)
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
        clearAttention(agent.id)
        persistUISelection()
    }

    /// ⌘1–⌘9 — jump to the Nth agent tab in the selected folder.
    func selectAgentAtIndex(_ index: Int) {
        guard let folder = selectedFolder else { return }
        let agents = store.agents(in: folder.id)
        guard index < agents.count else { return }
        selectAgent(agents[index])
    }

    /// ⇧⌘] / ⇧⌘[ — cycle tabs within the selected folder.
    func selectAdjacentAgent(by offset: Int) {
        guard let folder = selectedFolder else { return }
        let agents = store.agents(in: folder.id)
        guard !agents.isEmpty else { return }
        let idx = selectedAgent.flatMap { a in agents.firstIndex { $0.id == a.id } } ?? 0
        let next = ((idx + offset) % agents.count + agents.count) % agents.count
        selectAgent(agents[next])
    }

    /// Folders as the sidebar lists them (respects the "open agents only" toggle).
    var sidebarFolders: [Folder] {
        store.sidebarOpenAgentsOnly ? store.foldersWithAgents() : store.sortedFolders()
    }

    /// ⌘↑ / ⌘↓ — move through the sidebar's folders (no wrap, like a list).
    func selectAdjacentFolder(by offset: Int) {
        let folders = sidebarFolders
        guard !folders.isEmpty else { return }
        guard let idx = folders.firstIndex(where: { $0.id == selectedFolderID }) else {
            selectFolder(folders[offset > 0 ? 0 : folders.count - 1].id)
            return
        }
        let next = min(max(idx + offset, 0), folders.count - 1)
        if next != idx { selectFolder(folders[next].id) }
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
        controlClient.onPanesChanged = { [weak self] in
            self?.recomputeStatuses()
        }
    }

    func startStatusPolling() {
        statusTimer?.invalidate()
        refreshStatuses()
        if let tmux { resourceMonitor.start(tmux: tmux) }
        // Slow safety net only — the control-mode client is the primary,
        // near-instant path. If it silently dies this still catches up.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatuses() }
        }
        // "running" decays to "waiting" with no new event, so re-evaluate
        // the in-memory snapshot every second (no process spawn involved).
        recomputeTimer?.invalidate()
        recomputeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recomputeStatuses() }
        }
    }

    private var liveSessions: Set<String> = []

    func refreshStatuses() {
        guard let tmux else { return }
        liveSessions = tmux.listSessions()
        refreshOrphans(live: liveSessions)
        recomputeStatuses()
    }

    /// Three-way status from the control-mode pane snapshot:
    /// exited (session gone) / idle (only a shell) / running (recent output)
    /// / waiting (tool up but quiet, or a hook said it needs you).
    func recomputeStatuses() {
        let now = Date().timeIntervalSince1970
        var changed = false
        let remoteFolders = Set(store.folders.filter(\.isRemote).map(\.id))
        for agent in store.agents {
            let new: AgentStatus
            if !liveSessions.isEmpty && !liveSessions.contains(agent.tmuxSession) {
                new = .exited
            } else if let pane = controlClient.panes[agent.tmuxSession] {
                // Remote panes always run the local `sh -c` ssh wrapper, so
                // "only a shell" can't be told apart there: never idle.
                if Self.shellCommands.contains(pane.command) && !remoteFolders.contains(agent.folderID) {
                    new = .idle
                } else if attention.contains(agent.id) {
                    new = .waiting
                } else if now - pane.activity <= Self.runningWindow {
                    new = .running
                } else {
                    new = .waiting
                }
            } else if liveSessions.contains(agent.tmuxSession) {
                new = .unknown
            } else {
                continue
            }
            let old = agentStatuses[agent.id]
            if old != new {
                agentStatuses[agent.id] = new
                changed = true
            }
            // Quiet-after-running heuristic (for persistent tools without
            // hooks, e.g. OpenCode). Plain shells go quiet between commands
            // all the time — no ding for those.
            let isToolAgent = !store.preset(for: agent.presetID).command.isEmpty
            switch new {
            case .running:
                quietSince.removeValue(forKey: agent.id)
                dingedThisEpisode.remove(agent.id)
            case .waiting:
                if old == .running { quietSince[agent.id] = now }
                if isToolAgent,
                   let since = quietSince[agent.id],
                   now - since >= Self.quietBeforeDing,
                   !dingedThisEpisode.contains(agent.id),
                   now - (lastHookAt[agent.id] ?? 0) > 10,
                   !isBeingWatched(agent.id) {
                    dingedThisEpisode.insert(agent.id)
                    flagAttention(agent.id)
                    playAttentionSound()
                    HookLog.write("quiet-after-running -> attention for \(agent.tmuxSession)")
                }
            default:
                quietSince.removeValue(forKey: agent.id)
                dingedThisEpisode.remove(agent.id)
            }
        }
        _ = changed
    }

    // MARK: Sound

    func playAttentionSound() {
        let name = store.attentionSound
        guard !name.isEmpty, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.5
        sound.play()
    }

    // MARK: Attention (hooks) & dock badge

    func flagAttention(_ agentID: Agent.ID) {
        attention.insert(agentID)
        recomputeStatuses()
        updateDockBadge()
    }

    func clearAttention(_ agentID: Agent.ID) {
        guard attention.remove(agentID) != nil else { return }
        recomputeStatuses()
        updateDockBadge()
    }

    private func updateDockBadge() {
        NSApp?.dockTile.badgeLabel = attention.isEmpty ? nil : "\(attention.count)"
    }

    func sessionName(forPaneID paneID: String) -> String? {
        controlClient.sessionName(forPaneID: paneID)
    }

    func liveTitle(for agent: Agent) -> String? {
        liveTitles[agent.tmuxSession]
    }

    func resourceUsage(for agent: Agent) -> ResourceUsage? {
        let usage = resourceMonitor.usageBySession[agent.tmuxSession]
        return usage?.isNegligible == true ? nil : usage
    }

    private func refreshOrphans(live: Set<String>) {
        guard let tmux else { orphanSessions = []; return }
        let known = Set(store.agents.map { $0.tmuxSession })
        let untracked = live.filter { !$0.hasPrefix("__ao_") && !known.contains($0) }
        orphanSessions = untracked.sorted().map { name in
            let cwd = tmux.paneCurrentPath(session: name)
            let match = cwd.flatMap { path in
                store.folders.first { !$0.isRemote && path.hasPrefix($0.path.path) }
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

    /// HBY-13: a folder on another machine, reached over ssh. Uses the
    /// user's ssh setup as-is (config aliases, keys, agent).
    func presentAddRemoteFolderPanel() {
        let alert = NSAlert()
        alert.messageText = "Add Remote Folder"
        alert.informativeText = "Agents run in tmux on the remote host (which needs tmux and the agent CLIs installed) and keep running while this Mac is offline."
        let host = NSTextField(string: "")
        host.placeholderString = "Host — user@devbox or an ~/.ssh/config alias"
        let path = NSTextField(string: "")
        path.placeholderString = "Absolute path — /home/you/project"
        let stack = NSStackView(views: [host, path])
        stack.orientation = .vertical
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 52)
        host.frame.size.width = 320
        path.frame.size.width = 320
        alert.accessoryView = stack
        alert.window.initialFirstResponder = host
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let h = host.stringValue.trimmingCharacters(in: .whitespaces)
        let p = path.stringValue.trimmingCharacters(in: .whitespaces)
        // shortcut: no `~` expansion (remote home unknown locally); require absolute.
        guard !h.isEmpty, !h.contains(" "), p.hasPrefix("/") else {
            let err = NSAlert()
            err.messageText = "Need a host and an absolute path (starting with /)."
            err.runModal()
            return
        }
        if let folder = store.addRemoteFolder(host: h, path: p) { selectFolder(folder.id) }
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

    /// ⌘T — plain shell at the selected folder's root, no sheet.
    func newShellInSelectedFolder() {
        guard let folder = selectedFolder else { return }
        createAgent(folder: folder, preset: store.preset(for: AgentPreset.shell.id), relativeCwd: "")
    }

    func createAgent(folder: Folder, preset: AgentPreset, relativeCwd: String) {
        let session = "ao_\(Self.slug(folder.displayName))_\(UUID().uuidString.prefix(8).lowercased())"
        let agent = Agent(folderID: folder.id, relativeCwd: relativeCwd, presetID: preset.id, tmuxSession: session)
        let cwd = agent.resolvedCwd(folderPath: folder.path)
        if let host = folder.host {
            let launch = RemoteSession.launchCommand(host: host, session: session, cwd: cwd.path, command: preset.command)
            tmux?.ensureSession(name: session, cwd: FileManager.default.homeDirectoryForCurrentUser, command: launch)
        } else {
            tmux?.ensureSession(name: session, cwd: cwd, command: preset.command.isEmpty ? nil : preset.command)
        }
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
        clearAttention(agent.id)
        persistUISelection()
    }

    /// Kill the pane's current process, get a fresh shell, then run the
    /// tool's resume command (or its launch command if it has none).
    func restartAgent(_ agent: Agent) {
        guard let folder = store.folder(agent.folderID) else { return }
        let preset = store.preset(for: agent.presetID)
        let command = preset.resumeCommand ?? preset.command
        if let host = folder.host {
            let restart = RemoteSession.restartCommand(host: host, session: agent.tmuxSession,
                                                       cwd: agent.resolvedCwd(folderPath: folder.path).path, command: command)
            tmux?.respawn(session: agent.tmuxSession, cwd: FileManager.default.homeDirectoryForCurrentUser, command: restart)
            return
        }
        tmux?.respawn(session: agent.tmuxSession,
                      cwd: agent.resolvedCwd(folderPath: folder.path),
                      command: command.isEmpty ? nil : command)
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

    func folderNeedsAttention(_ folderID: Folder.ID) -> Bool {
        store.agents(in: folderID).contains { attention.contains($0.id) }
    }

    /// One orb for the whole folder, same palette as the tabs. Most
    /// urgent wins: exited > waiting > running > idle. nil = no agents.
    func folderStatus(_ folderID: Folder.ID) -> AgentStatus? {
        let statuses = store.agents(in: folderID).map { agentStatuses[$0.id] ?? .unknown }
        guard !statuses.isEmpty else { return nil }
        if statuses.contains(.exited) { return .exited }
        if statuses.contains(.waiting) { return .waiting }
        if statuses.contains(.running) { return .running }
        if statuses.contains(.idle) { return .idle }
        return .unknown
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
