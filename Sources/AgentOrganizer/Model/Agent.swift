import Foundation

/// Live status of an agent's tmux session, refreshed by polling `has-session`
/// (cheap: a single local socket round-trip) — never by tearing anything down.
enum AgentStatus: Equatable {
    /// Tool is producing output (activity within the last couple of seconds).
    case running
    /// Tool is up but quiet — most likely waiting for the user. Also forced
    /// by a Claude Code `Notification`/`Stop` hook until the tab is viewed.
    case waiting
    /// Nothing but the login shell is running in the pane.
    case idle
    /// The tmux session is gone.
    case exited
    case unknown
}

/// One launched tool instance inside a folder. Backed 1:1 by a tmux session
/// that outlives the app. Never hidden, never auto-detached: as long as the
/// agent exists in the sidebar, its terminal view stays instantiated.
struct Agent: Identifiable, Codable, Hashable {
    let id: UUID
    var folderID: UUID
    /// Empty = folder root. Otherwise a path relative to the folder, e.g. "services/api".
    var relativeCwd: String
    var presetID: String
    /// User-provided rename; falls back to the preset name when nil.
    var title: String?
    var tmuxSession: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        folderID: UUID,
        relativeCwd: String = "",
        presetID: String,
        tmuxSession: String
    ) {
        self.id = id
        self.folderID = folderID
        self.relativeCwd = relativeCwd
        self.presetID = presetID
        self.title = nil
        self.tmuxSession = tmuxSession
        self.createdAt = Date()
    }

    func resolvedCwd(folderPath: URL) -> URL {
        relativeCwd.isEmpty ? folderPath : folderPath.appendingPathComponent(relativeCwd)
    }
}
