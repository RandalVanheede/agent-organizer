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
    private var controlClient = TmuxControlModeClient()
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
    /// Unix seconds when each agent entered its current status (sidebar Agents panel ages).
    var statusSince: [Agent.ID: TimeInterval] = [:]
    /// tmux session name -> latest live pane title (from control mode window
    /// renames), overridden by a user-set `Agent.title` when present.
    var liveTitles: [String: String] = [:]
    /// session name -> tool-set pane title (observable mirror of the
    /// control client's snapshot, so tabs redraw when it changes).
    var paneTitles: [String: String] = [:]
    var orphanSessions: [OrphanSession] = []
    /// Agents a Claude Code hook flagged as needing the user (Notification /
    /// Stop). Cleared when the tab is viewed. Drives the dock badge.
    var attention: [Agent.ID: Attention] = [:]
    struct Attention {
        enum Kind { case needsInput, finished }
        let kind: Kind
        /// Unix seconds; orders the sidebar lists oldest first.
        let since: TimeInterval
    }
    /// Quick Open (⌘P) sheet.
    var quickOpenPresented = false
    /// Killed agents still inside their undo window: record gone from the
    /// store, session (and cached terminal) still alive.
    private struct PendingKill {
        let agent: Agent
        let index: Int
        /// The agent that followed it, so undo restores the order even after
        /// other kills shifted indexes.
        let nextAgentID: Agent.ID?
        let host: String?
        let task: Task<Void, Never>
    }
    private var pendingKills: [Agent.ID: PendingKill] = [:]
    /// Matches the toast's on-screen time.
    private static let killGrace: Duration = .seconds(8)
    private var statusTimer: Timer?
    private var recomputeTimer: Timer?
    /// Shells: a pane running only one of these is "idle".
    private static let shellCommands: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "tcsh", "ksh", "nu", "login", "-zsh", "-bash"]
    /// Output this long after a prompt appeared means it was answered.
    private static let answeredAfter: TimeInterval = 3
    /// Output within this window makes a hook-less tool "running"…
    private static let runningWindow: TimeInterval = 2.5
    /// …and it stays running until quiet this long (no flicker between bursts).
    private static let runningHold: TimeInterval = 6
    /// A hook-reported turn with no output for this long was most likely
    /// interrupted (Esc fires no `Stop`); Claude's spinner redraws while working.
    private static let stalledTurnAfter: TimeInterval = 15
    /// Agents whose Claude hooks have reported in this run. Together with
    /// any pane running Claude while hooks are installed, their running/done
    /// comes from turn boundaries, not from screen output (a click or a
    /// tab-switch redraw must not read as "working").
    private var hookAware: Set<Agent.ID> = []
    @ObservationIgnored private var hooksInstalled = HookInstaller.isInstalled()
    /// Hook-driven agents between `UserPromptSubmit` and `Stop`; persisted.
    @ObservationIgnored private var turnActive: Set<Agent.ID> = [] {
        didSet {
            let sessions = Set(store.agents.filter { turnActive.contains($0.id) }.map(\.tmuxSession))
            store.setActiveTurnSessions(sessions)
        }
    }

    /// Claude Code shows up in tmux as its version, e.g. "2.1.319".
    private static func isClaudeCommand(_ command: String) -> Bool {
        let parts = command.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
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
    /// Claude Code sub-agents still working per agent (SubagentStart/Stop
    /// hooks). Non-empty = busy even when the main turn has stopped.
    /// shortcut: a sub-agent killed without SubagentStop stays counted until
    /// the tool exits/restarts; add a timeout if that shows up in practice.
    private var activeSubagents: [Agent.ID: Set<String>] = [:]

    init() {
        #if DEBUG
        QuickOpenRanking.selfCheck()
        #endif
        cache.store = store
        tmux = TmuxController()
        tmux?.recoverIfWedged()
        reconcileSessions()
        wireControlClient()
        for folder in store.folders { watcher.watch(folder) }
        watcher.onChange = { [weak self] id in self?.handleFolderChanged(id) }
        turnActive = Set(store.agents.filter { store.activeTurnSessions.contains($0.tmuxSession) }.map(\.id))
        hookWatcher.onEvent = { [weak self] event in self?.handleHookEvent(event) }
        hookWatcher.start()
        HookInstaller.upgradeIfNeeded()
        restoreUISelection()
    }

    // MARK: Claude Code hooks → attention + system notifications

    private func handleHookEvent(_ event: HookEventWatcher.Event) {
        let session = sessionName(forPaneID: event.pane) ?? tmux?.sessionName(forPane: event.pane)
        guard let session, let agent = store.agents.first(where: { $0.tmuxSession == session }) else {
            HookLog.write("event \(event.name) pane=\(event.pane) -> no agent (session=\(session ?? "nil"))")
            return
        }
        HookLog.write("event \(event.name) pane=\(event.pane) -> \(session) sub=\(event.subagentID ?? "-") active=\(activeSubagents[agent.id]?.count ?? 0)")
        lastHookAt[agent.id] = Date().timeIntervalSince1970
        hookAware.insert(agent.id)
        hooksInstalled = true

        switch event.name {
        case "UserPromptSubmit":
            turnActive.insert(agent.id)
            clearAttention(agent.id)
            recomputeStatuses()
        case "SubagentStart", "SubagentStop":
            guard let id = event.subagentID else { break }
            if event.name == "SubagentStart" {
                activeSubagents[agent.id, default: []].insert(id)
            } else {
                activeSubagents[agent.id]?.remove(id)
            }
            recomputeStatuses()
        case "Stop" where !(activeSubagents[agent.id]?.isEmpty ?? true):
            // Main turn ended but background sub-agents still work: not done.
            break
        case "Notification", "Stop":
            let kind: Attention.Kind
            if event.name == "Stop" {
                turnActive.remove(agent.id)
                kind = .finished
            } else {
                switch Self.notificationKind(type: event.notificationType, message: event.message) {
                case .ignore: return
                // Claude's "waiting for your input" nudge after a minute idle:
                // the turn already finished, so only flag it if nothing is yet.
                case .idleReminder:
                    guard attention[agent.id] == nil else { return }
                    kind = .finished
                case .blocked: kind = .needsInput
                }
            }
            let watched = isBeingWatched(agent.id)
            // Watching the tab: a finished turn is already seen, but a prompt
            // still blocks until answered, so it's recorded quietly.
            if watched && kind == .finished { break }
            flagAttention(agent.id, kind)
            guard !watched else { break }
            playAttentionSound()
            let folderName = store.folder(agent.folderID)?.displayName ?? ""
            let title = displayTitle(for: agent)
            postNotification(
                agentID: agent.id,
                title: folderName.isEmpty ? title : "\(title) — \(folderName)",
                body: kind == .finished ? "Finished. Ready for your next prompt." : (event.message ?? "Needs your input.")
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
        Task { [weak self] in
            let center = UNUserNotificationCenter.current()
            let status = await center.notificationSettings().authorizationStatus
            if status == .authorized || status == .provisional {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = nil // playAttentionSound() already rang
                content.userInfo = ["agentID": agentID.uuidString]
                let request = UNNotificationRequest(identifier: "agent-\(agentID.uuidString)", content: content, trigger: nil)
                do {
                    try await center.add(request)
                    HookLog.write("system notification: \"\(title)\"")
                } catch {
                    HookLog.write("system notification failed: \(error.localizedDescription)")
                }
            } else {
                HookLog.write("toast (system notifications not allowed, status=\(status.rawValue)): \"\(title)\"")
                ToastCenter.shared.show(title: title, body: body) { [weak self] in
                    self?.selectAgent(id: agentID)
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
        // Seeing a finished turn settles it; a pending prompt needs an answer.
        if attention[agent.id]?.kind == .finished { clearAttention(agent.id) }
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

    /// Folders as the sidebar lists them (respects the "open agents only"
    /// toggle). The selected folder always stays listed, so one picked via
    /// Quick Open shows where you are even without agents.
    var sidebarFolders: [Folder] {
        guard store.sidebarOpenAgentsOnly else { return store.sortedFolders() }
        let withAgents = Set(store.agents.map(\.folderID))
        return store.sortedFolders().filter { withAgents.contains($0.id) || $0.id == selectedFolderID }
    }

    /// Agents blocked on you (permission prompt / question), oldest first.
    var needsYouAgents: [Agent] { agents(flagged: .needsInput) }
    /// Agents whose turn finished and that you haven't looked at yet.
    var finishedAgents: [Agent] { agents(flagged: .finished) }

    private func agents(flagged kind: Attention.Kind) -> [Agent] {
        store.agents
            .compactMap { agent in attention[agent.id].flatMap { $0.kind == kind ? (agent, $0.since) : nil } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// ⌘J — cycle through agents needing you, then unseen finished ones.
    func selectNextAgentToCheck() {
        let queue = needsYouAgents + finishedAgents
        guard !queue.isEmpty else { NSSound.beep(); return }
        let idx = selectedAgent.flatMap { current in queue.firstIndex { $0.id == current.id } }
        selectAgent(queue[idx.map { ($0 + 1) % queue.count } ?? 0])
    }

    /// User-set name, else the tool's live title, else the preset name.
    func displayTitle(for agent: Agent) -> String {
        agent.title ?? liveTitle(for: agent) ?? store.preset(for: agent.presetID).name
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
            guard let self else { return }
            let titles = controlClient.panes.filter { !Self.shellCommands.contains($0.value.command) }.mapValues(\.title)
            if titles != paneTitles { paneTitles = titles }
            recomputeStatuses()
        }
        // Server shut down under us: once it's gone, reconnect with a fresh
        // client (a Process can't be re-run) so live status keeps working.
        controlClient.onEnded = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let self else { return }
                self.controlClient = TmuxControlModeClient()
                self.recheckTmux()
            }
        }
    }

    func startStatusPolling() {
        statusTimer?.invalidate()
        refreshStatuses()
        // Only our agents' panes: a pane title can forge extra subscription
        // entries (see TmuxControlModeClient), so never walk arbitrary pids.
        resourceMonitor.start { [weak self] in
            guard let self else { return [:] }
            let ours = Set(self.store.agents.map(\.tmuxSession))
            return self.controlClient.panes.filter { ours.contains($0.key) }.mapValues(\.pid)
        }
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

    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var refreshInFlight = false
    @ObservationIgnored private var refreshPending = false

    /// Queries tmux off the main thread (a slow or stuck server must never
    /// freeze the UI). At most one query runs; requests arriving meanwhile
    /// collapse into one follow-up pass. A result is dropped if local state
    /// changed after it started (`refreshGeneration`).
    func refreshStatuses() {
        guard let tmux else { return }
        refreshGeneration += 1
        guard !refreshInFlight else { refreshPending = true; return }
        refreshInFlight = true
        let generation = refreshGeneration
        let known = Set(store.agents.map(\.tmuxSession)).union(pendingKills.values.map(\.agent.tmuxSession))
        Task.detached { [weak self] in
            let live = tmux.listSessions()
            let untracked = live.filter { !$0.hasPrefix("__ao_") && !known.contains($0) }.sorted()
            let cwds = untracked.map { (name: $0, cwd: tmux.paneCurrentPath(session: $0)) }
            await MainActor.run {
                guard let self else { return }
                self.refreshInFlight = false
                if self.refreshPending || generation != self.refreshGeneration {
                    self.refreshPending = false
                    self.refreshStatuses()
                    return
                }
                self.liveSessions = live
                self.orphanSessions = cwds.map { entry in
                    let match = entry.cwd.flatMap { path in
                        self.store.folders.first { !$0.isRemote && path.hasPrefix($0.path.path) }
                    }
                    return OrphanSession(name: entry.name, cwd: entry.cwd, matchingFolderID: match?.id)
                }
                self.recomputeStatuses()
            }
        }
    }

    /// Status from the control-mode pane snapshot: exited (session gone) /
    /// idle (only a shell) / waiting (a hook says it's blocked on you) /
    /// running (recent output) / done (tool up and quiet).
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
                } else if let flag = attention[agent.id], flag.kind == .needsInput,
                          pane.activity <= flag.since + Self.answeredAfter {
                    new = .waiting
                } else if !(activeSubagents[agent.id]?.isEmpty ?? true) {
                    new = .running
                } else if hookAware.contains(agent.id) || (hooksInstalled && Self.isClaudeCommand(pane.command)) {
                    // Turn boundaries from hooks: typing or a redraw on tab
                    // switch doesn't count as working, a pause mid-turn does.
                    let working = turnActive.contains(agent.id) && now - pane.activity <= Self.stalledTurnAfter
                    new = working ? .running : .done
                } else {
                    let quiet = now - pane.activity
                    let wasRunning = agentStatuses[agent.id] == .running
                    new = quiet <= Self.runningWindow || (wasRunning && quiet <= Self.runningHold) ? .running : .done
                }
                // Output well after the prompt appeared = it was answered.
                if let flag = attention[agent.id], flag.kind == .needsInput, new != .waiting {
                    attention.removeValue(forKey: agent.id)
                    updateDockBadge()
                }
            } else if liveSessions.contains(agent.tmuxSession) {
                new = .unknown
            } else {
                continue
            }
            let old = agentStatuses[agent.id]
            if old != new {
                agentStatuses[agent.id] = new
                statusSince[agent.id] = Date().timeIntervalSince1970
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
            case .done:
                if old == .running { quietSince[agent.id] = now }
                if isToolAgent,
                   let since = quietSince[agent.id],
                   now - since >= Self.quietBeforeDing,
                   !dingedThisEpisode.contains(agent.id),
                   now - (lastHookAt[agent.id] ?? 0) > 10,
                   !isBeingWatched(agent.id) {
                    dingedThisEpisode.insert(agent.id)
                    flagAttention(agent.id, .finished)
                    playAttentionSound()
                    HookLog.write("quiet-after-running -> attention for \(agent.tmuxSession)")
                }
            default:
                quietSince.removeValue(forKey: agent.id)
                dingedThisEpisode.remove(agent.id)
                // Tool gone (back to shell / session dead): its sub-agents and flags too.
                if new == .idle || new == .exited {
                    activeSubagents.removeValue(forKey: agent.id)
                    turnActive.remove(agent.id)
                    if attention.removeValue(forKey: agent.id) != nil { updateDockBadge() }
                }
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

    func flagAttention(_ agentID: Agent.ID, _ kind: Attention.Kind) {
        // A pending prompt outranks a finished turn.
        if attention[agentID]?.kind == .needsInput && kind == .finished { return }
        attention[agentID] = Attention(kind: kind, since: Date().timeIntervalSince1970)
        recomputeStatuses()
        updateDockBadge()
    }

    func clearAttention(_ agentID: Agent.ID) {
        guard attention.removeValue(forKey: agentID) != nil else { return }
        recomputeStatuses()
        updateDockBadge()
    }

    private func updateDockBadge() {
        NSApp?.dockTile.badgeLabel = attention.isEmpty ? nil : "\(attention.count)"
    }

    func sessionName(forPaneID paneID: String) -> String? {
        controlClient.sessionName(forPaneID: paneID)
    }

    /// The tool's own pane title (Claude Code sets a topic summary, e.g.
    /// "✳ Fix login bug") wins over the window name, which is just the
    /// process name. Shell panes are skipped: zsh titles are "user@host:~".
    func liveTitle(for agent: Agent) -> String? {
        if let paneTitle = paneTitles[agent.tmuxSession], !paneTitle.isEmpty {
            var title = Substring(paneTitle)
            // Drop Claude's status glyph (✳ idle / braille spinner) prefix.
            if let first = title.first, !first.isLetter, !first.isNumber,
               title.dropFirst().first == " " {
                title = title.dropFirst(2)
            }
            if !title.isEmpty { return String(title) }
        }
        return liveTitles[agent.tmuxSession]
    }

    func resourceUsage(for agent: Agent) -> ResourceUsage? {
        let usage = resourceMonitor.usageBySession[agent.tmuxSession]
        return usage?.isNegligible == true ? nil : usage
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
        tmux?.recoverIfWedged()
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
        // Plain frames: an NSStackView accessory collapses the fields to zero width.
        let host = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        host.placeholderString = "Host — user@devbox or ~/.ssh/config alias"
        let path = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        path.placeholderString = "Absolute path — /home/you/project"
        host.nextKeyView = path
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
        container.addSubview(host)
        container.addSubview(path)
        alert.accessoryView = container
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
        startSession(for: agent, in: folder, command: preset.command)
        store.addAgent(agent)
        liveSessions.insert(session) // an in-flight refresh mustn't mark it exited
        refreshStatuses()
        selectAgent(agent)
        newAgentPopoverFolderID = nil
    }

    @discardableResult
    private func startSession(for agent: Agent, in folder: Folder, command: String) -> Bool {
        let cwd = agent.resolvedCwd(folderPath: folder.path)
        if let host = folder.host {
            let launch = RemoteSession.launchCommand(host: host, session: agent.tmuxSession, cwd: cwd.path, command: command)
            return tmux?.ensureSession(name: agent.tmuxSession, cwd: FileManager.default.homeDirectoryForCurrentUser, command: nil, paneCommand: launch) ?? false
        }
        return tmux?.ensureSession(name: agent.tmuxSession, cwd: cwd, command: command.isEmpty ? nil : command) ?? false
    }

    /// Bumped when an agent's terminal view is replaced, so its pane gets a
    /// new SwiftUI identity and attaches the fresh view.
    var terminalEpochs: [Agent.ID: Int] = [:]

    /// Closing a tab is undoable for a few seconds: the record and tab go
    /// away now, the session only after the grace period (or on quit).
    /// An agent whose session already ended is removed right away.
    func killAgent(_ agent: Agent) {
        let host = store.folder(agent.folderID)?.host
        let alreadyEnded = agentStatuses[agent.id] == .exited
        let nextAgentID = store.agents.firstIndex { $0.id == agent.id }
            .flatMap { store.agents.indices.contains($0 + 1) ? store.agents[$0 + 1].id : nil }
        guard let index = store.detachAgent(agent) else { return }
        if activeAgentByFolder[agent.folderID] == agent.id {
            activeAgentByFolder.removeValue(forKey: agent.folderID)
        }
        if splitAgentID == agent.id { splitAgentID = nil }
        clearAttention(agent.id)
        persistUISelection()

        if alreadyEnded {
            cache.discard(agent.id)
            store.killSessions(of: agent, host: host, tmux: tmux)
            return
        }
        let title = displayTitle(for: agent)
        let task = Task { [weak self] in
            try? await Task.sleep(for: Self.killGrace)
            guard !Task.isCancelled else { return }
            self?.finalizeKill(agent.id)
        }
        pendingKills[agent.id] = PendingKill(agent: agent, index: index, nextAgentID: nextAgentID, host: host, task: task)
        ToastCenter.shared.show(title: "Killed \(title)", body: "Click to undo.", icon: "arrow.uturn.backward") { [weak self] in
            self?.undoKill(agent.id)
        }
    }

    private func finalizeKill(_ id: Agent.ID) {
        guard let pending = pendingKills.removeValue(forKey: id) else { return }
        pending.task.cancel()
        cache.discard(id)
        store.killSessions(of: pending.agent, host: pending.host, tmux: tmux)
    }

    private func undoKill(_ id: Agent.ID) {
        guard let pending = pendingKills[id] else { return }
        // Its folder was removed meanwhile: nothing to put the tab back into.
        guard store.folder(pending.agent.folderID) != nil else { return finalizeKill(id) }
        pendingKills.removeValue(forKey: id)
        pending.task.cancel()
        let index = pending.nextAgentID.flatMap { next in store.agents.firstIndex { $0.id == next } } ?? pending.index
        store.reinsertAgent(pending.agent, at: index)
        selectAgent(pending.agent)
    }

    /// On quit: kills still in their undo window happen now, so they don't
    /// come back as unmanaged sessions next launch.
    func finalizePendingKills() {
        for id in Array(pendingKills.keys) { finalizeKill(id) }
    }

    /// Kill the pane's current process, get a fresh shell, then run the
    /// tool's resume command (or its launch command if it has none). A
    /// session that already ended is started fresh under the same name.
    func restartAgent(_ agent: Agent) {
        guard let folder = store.folder(agent.folderID) else { return }
        let preset = store.preset(for: agent.presetID)
        let command = preset.resumeCommand ?? preset.command
        if agentStatuses[agent.id] == .exited {
            guard startSession(for: agent, in: folder, command: command) else {
                NSSound.beep() // e.g. its folder was deleted; the card stays up
                return
            }
            cache.discard(agent.id) // the old attach client died with the session
            terminalEpochs[agent.id, default: 0] += 1
            liveSessions.insert(agent.tmuxSession) // don't flash "exited" until the refresh lands
            agentStatuses[agent.id] = .unknown
            refreshStatuses()
            return
        }
        if let host = folder.host {
            let restart = RemoteSession.restartCommand(host: host, session: agent.tmuxSession,
                                                       cwd: agent.resolvedCwd(folderPath: folder.path).path, command: command)
            tmux?.respawn(session: agent.tmuxSession, cwd: FileManager.default.homeDirectoryForCurrentUser, command: nil, paneCommand: restart)
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
        store.agents(in: folderID).contains { attention[$0.id] != nil }
    }

    /// One orb for the whole folder, same palette as the tabs. Most
    /// urgent wins: exited > waiting > running > idle. nil = no agents.
    func folderStatus(_ folderID: Folder.ID) -> AgentStatus? {
        let statuses = store.agents(in: folderID).map { agentStatuses[$0.id] ?? .unknown }
        guard !statuses.isEmpty else { return nil }
        if statuses.contains(.exited) { return .exited }
        if statuses.contains(.waiting) { return .waiting }
        if statuses.contains(.running) { return .running }
        if statuses.contains(.done) { return .done }
        if statuses.contains(.idle) { return .idle }
        return .unknown
    }

    func setTerminalFontSize(_ size: Double) {
        store.setTerminalFontSize(size)
        cache.applyFontSize(store.terminalFontSize)
    }

    enum NotificationKind { case blocked, idleReminder, ignore }

    /// Claude Code's Notification hook covers several things; only some
    /// mean it's blocked. `notification_type` when present, else the text.
    static func notificationKind(type: String?, message: String?) -> NotificationKind {
        switch type {
        case "idle_prompt": return .idleReminder
        case "auth_success": return .ignore
        case .some: return .blocked // permission_prompt, elicitation_dialog, future kinds
        case nil:
            return (message ?? "").localizedCaseInsensitiveContains("waiting for your input") ? .idleReminder : .blocked
        }
    }

    private static func slug(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = text.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped)
    }
}
