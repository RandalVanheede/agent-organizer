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
    }

    func save() {
        let state = PersistedState(
            folders: folders,
            agents: agents,
            presets: presets,
            killAgentsOnQuit: killAgentsOnQuit,
            terminalFontSize: terminalFontSize
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func sortedFolders() -> [Folder] {
        folders.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
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
        guard !folders.contains(where: { $0.path.standardizedFileURL == standardized }) else { return nil }
        var folder = Folder(path: standardized)
        applyScan(to: &folder)
        folders.append(folder)
        save()
        return folder
    }

    private func applyScan(to folder: inout Folder) {
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
            for agent in related { tmux?.killSession(agent.tmuxSession) }
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
        tmux?.killSession(agent.tmuxSession)
        agents.removeAll { $0.id == agent.id }
        save()
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

    func setTerminalFontSize(_ size: Double) {
        terminalFontSize = min(max(size, 9), 24)
        save()
    }
}
