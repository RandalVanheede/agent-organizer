import Foundation

/// A launchable tool: what command to run in a fresh pane, and how to resume
/// a previous session of it (when the tool supports that).
struct AgentPreset: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var command: String
    var resumeCommand: String?
    var icon: String

    static let claude = AgentPreset(
        id: "claude",
        name: "Claude Code",
        command: "claude",
        resumeCommand: "claude --continue",
        icon: "sparkles"
    )

    static let opencode = AgentPreset(
        id: "opencode",
        name: "OpenCode",
        command: "opencode",
        resumeCommand: nil,
        icon: "terminal"
    )

    static let shell = AgentPreset(
        id: "shell",
        name: "Shell",
        command: "",
        resumeCommand: nil,
        icon: "chevron.left.forwardslash.chevron.right"
    )

    static let defaults: [AgentPreset] = [.claude, .opencode, .shell]
}
