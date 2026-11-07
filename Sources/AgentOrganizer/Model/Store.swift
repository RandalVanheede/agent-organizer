import Foundation
import Observation

/// App state + persistence. One JSON file, written on every mutation.
/// No agent is ever removed from here except by an explicit user action
/// (kill / remove folder) — there is no idle/hidden bookkeeping.
@Observable
final class Store {
    var folders: [Folder] = []
    var agents: [Agent] = []
    var presets: [AgentPreset] = AgentPreset.defaults
    var killAgentsOnQuit: Bool = false
    var terminalFontSize: Double = 13
    /// UI continuity across launches: which folder was open, and which
    /// agent tab was active in each folder (keyed by uuidString).
    var lastSelectedFolderID: UUID?
    var activeAgentByFolder: [String: String] = [:]
    /// System sound name played when an agent needs attention; "" = silent.
    var attentionSound: String = "Glass"
    /// Sidebar filter: hide folders that have no agents (= no live tmux session).
    var sidebarOpenAgentsOnly: Bool = false
    /// User-changed shortcuts keyed by `ShortcutAction.rawValue`; absent = default.
    var shortcutOverrides: [String: KeyCombo] = [:]

    private let fileURL: URL

    init() {
        let supportDir = Store.appSupportDirectory()
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        self.fileURL = supportDir.appendingPathComponent("state.json")
        load()
    }

    static func appSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Agent Organizer", isDirectory: true)
    }

    private struct PersistedState: Codable {
        var folders: [Folder]
        var agents: [Agent]
        var presets: [AgentPreset]
        var killAgentsOnQuit: Bool
        var terminalFontSize: Double?
        var lastSelectedFolderID: UUID?
        var activeAgentByFolder: [String: String]?
        var attentionSound: String?
        var sidebarOpenAgentsOnly: Bool?
        var shortcutOverrides: [String: KeyCombo]?
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return }
        folders = state.folders
        agents = state.agents
        if !state.presets.isEmpty { presets = state.presets }
        killAgentsOnQuit = state.killAgentsOnQuit
        terminalFontSize = state.terminalFontSize ?? 13
        lastSelectedFolderID = state.lastSelectedFolderID
        activeAgentByFolder = state.activeAgentByFolder ?? [:]
        attentionSound = state.attentionSound ?? "Glass"
        sidebarOpenAgentsOnly = state.sidebarOpenAgentsOnly ?? false
        shortcutOverrides = state.shortcutOverrides ?? [:]
    }

    func save() {
        let state = PersistedState(
            folders: folders,
            agents: agents,
            presets: presets,
            killAgentsOnQuit: killAgentsOnQuit,
            terminalFontSize: terminalFontSize,
            lastSelectedFolderID: lastSelectedFolderID,
            activeAgentByFolder: activeAgentByFolder,
            attentionSound: attentionSound,
            sidebarOpenAgentsOnly: sidebarOpenAgentsOnly,
            shortcutOverrides: shortcutOverrides
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func sortedFolders() -> [Folder] {
        folders.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Folders with at least one agent. Agent records only outlive their
    /// session until the next reconcile, so this is "folders with open agents".
    func foldersWithAgents() -> [Folder] {
        let ids = Set(agents.map(\.folderID))
        return sortedFolders().filter { ids.contains($0.id) }
    }

    func agents(in folderID: UUID) -> [Agent] {
        agents.filter { $0.folderID == folderID }
    }

    func folder(_ id: UUID) -> Folder? {
        folders.first { $0.id == id }
    }

    @discardableResult
    func addFolder(url: URL) -> Folder? {
        let standardized = url.standardizedFileURL
        guard !folders.contains(where: { !$0.isRemote && $0.path.standardizedFileURL == standardized }) else { return nil }
        var folder = Folder(path: standardized)
        applyScan(to: &folder)
        folders.append(folder)
        save()
        return folder
    }

    /// Remote folders are never scanned (no local filesystem): always `.plain`.
    @discardableResult
    func addRemoteFolder(host: String, path: String) -> Folder? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !folders.contains(where: { $0.host == host && $0.path == url }) else { return nil }
        let folder = Folder(path: url, host: host)
        folders.append(folder)
        save()
        return folder
    }

    private func applyScan(to folder: inout Folder) {
        guard !folder.isRemote else { return }
        folder.kind = FolderScanner.detectKind(at: folder.path, scanDepth: folder.scanDepth)
        if case .repo = folder.kind {
            folder.rootBranch = FolderScanner.readBranch(at: folder.path)
        } else {
            folder.rootBranch = nil
        }
    }

    func removeFolder(_ folder: Folder, killAgents: Bool, tmux: TmuxController?) {
        let related = agents.filter { $0.folderID == folder.id }
        if killAgents {
            for agent in related { killSessions(of: agent, host: folder.host, tmux: tmux) }
        }
        agents.removeAll { $0.folderID == folder.id }
        folders.removeAll { $0.id == folder.id }
        save()
    }

    func rescan(_ folder: Folder) {
        guard let idx = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        applyScan(to: &folders[idx])
        save()
    }

    func preset(for id: String) -> AgentPreset {
        presets.first { $0.id == id } ?? .shell
    }

    func addAgent(_ agent: Agent) {
        agents.append(agent)
        save()
    }

    func removeAgent(_ agent: Agent, tmux: TmuxController?) {
        killSessions(of: agent, host: folder(agent.folderID)?.host, tmux: tmux)
        agents.removeAll { $0.id == agent.id }
        save()
    }

    /// Drops the record but leaves its session running (the grace period
    /// before an undoable kill). Returns its index for `reinsertAgent`.
    func detachAgent(_ agent: Agent) -> Int? {
        guard let idx = agents.firstIndex(where: { $0.id == agent.id }) else { return nil }
        agents.remove(at: idx)
        save()
        return idx
    }

    func reinsertAgent(_ agent: Agent, at index: Int) {
        agents.insert(agent, at: min(index, agents.count))
        save()
    }

    func killSessions(of agent: Agent, host: String?, tmux: TmuxController?) {
        tmux?.killSession(agent.tmuxSession)
        if let host { RemoteSession.kill(host: host, session: agent.tmuxSession) }
    }

    func renameAgent(_ agent: Agent, to title: String?) {
        guard let idx = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[idx].title = (title?.isEmpty ?? true) ? nil : title
        save()
    }

    /// Reorders agents within one folder only. Other folders' agents keep
    /// their existing relative position in the backing array untouched.
    func moveAgents(in folderID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        var subset = agents.filter { $0.folderID == folderID }
        subset.move(fromOffsets: source, toOffset: destination)
        var iterator = subset.makeIterator()
        for i in agents.indices where agents[i].folderID == folderID {
            if let next = iterator.next() { agents[i] = next }
        }
        save()
    }

    // MARK: Presets

    @discardableResult
    func addPreset(name: String, command: String, resumeCommand: String?, icon: String) -> AgentPreset {
        let preset = AgentPreset(
            id: "custom-\(UUID().uuidString.prefix(8).lowercased())",
            name: name,
            command: command,
            resumeCommand: (resumeCommand?.isEmpty ?? true) ? nil : resumeCommand,
            icon: icon
        )
        presets.append(preset)
        save()
        return preset
    }

    func updatePreset(_ preset: AgentPreset) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[idx] = preset
        save()
    }

    /// Refuses to remove a preset still in use by an existing agent, so no
    /// agent row is ever left pointing at nothing.
    @discardableResult
    func removePreset(_ preset: AgentPreset) -> Bool {
        guard !agents.contains(where: { $0.presetID == preset.id }) else { return false }
        presets.removeAll { $0.id == preset.id }
        save()
        return true
    }

    func setUISelection(folderID: UUID?, activeAgentByFolder: [String: String]) {
        lastSelectedFolderID = folderID
        self.activeAgentByFolder = activeAgentByFolder
        save()
    }

    func setAttentionSound(_ name: String) {
        attentionSound = name
        save()
    }

    func setSidebarOpenAgentsOnly(_ value: Bool) {
        sidebarOpenAgentsOnly = value
        save()
    }

    func setTerminalFontSize(_ size: Double) {
        terminalFontSize = min(max(size, 9), 24)
        save()
    }

    // MARK: Shortcuts

    /// nil = unbound.
    func shortcut(_ action: ShortcutAction) -> KeyCombo? {
        let combo = shortcutOverrides[action.rawValue] ?? action.defaultCombo
        return combo == .unbound ? nil : combo
    }

    /// Binds `combo` (nil = unbind). A combo can belong to one action only,
    /// so any other action holding it is unbound.
    func setShortcut(_ action: ShortcutAction, _ combo: KeyCombo?) {
        if let combo {
            for other in ShortcutAction.allCases where other != action && shortcut(other) == combo {
                storeShortcut(other, .unbound)
            }
        }
        storeShortcut(action, combo ?? .unbound)
        save()
    }

    func resetShortcuts() {
        shortcutOverrides = [:]
        save()
    }

    private func storeShortcut(_ action: ShortcutAction, _ combo: KeyCombo) {
        shortcutOverrides[action.rawValue] = combo == action.defaultCombo ? nil : combo
    }
}
