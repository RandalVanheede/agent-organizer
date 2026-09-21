import SwiftUI

/// Horizontal tabs along the top of a folder's canvas — one per agent, plus
/// a trailing `+` to create another. Mirrors the sidebar's vertical tabs.
struct AgentTabBar: View {
    @Environment(AppState.self) private var appState
    let folder: Folder

    private var agents: [Agent] { appState.store.agents(in: folder.id) }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(agents) { agent in
                        AgentTabView(agent: agent, isActive: appState.selectedAgent?.id == agent.id)
                    }
                }
                .padding(.horizontal, 6)
            }
            Button {
                appState.newAgentPopoverFolderID = folder.id
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Agent… (⌘N)")
            .padding(.trailing, 6)
        }
        .frame(height: 34)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct AgentTabView: View {
    @Environment(AppState.self) private var appState
    let agent: Agent
    let isActive: Bool

    @State private var isHovering = false
    @State private var renameRequested = false
    @State private var renameText = ""

    private var preset: AgentPreset { appState.store.preset(for: agent.presetID) }
    private var status: AgentStatus { appState.agentStatuses[agent.id] ?? .unknown }
    private var displayTitle: String {
        agent.title ?? appState.liveTitle(for: agent) ?? preset.name
    }
    private var subtitle: String? {
        guard !agent.relativeCwd.isEmpty else { return nil }
        let branch = appState.store.folder(agent.folderID)?
            .subRepos.first { $0.relativePath == agent.relativeCwd }?.branch
        return branch.map { "\(agent.relativeCwd) · \($0)" } ?? agent.relativeCwd
    }

    var body: some View {
        Button {
            appState.selectAgent(agent)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Image(systemName: preset.icon)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayTitle)
                        .font(.callout)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(minWidth: 90, maxWidth: 240, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : (isHovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? .primary : .secondary)
        .onHover { isHovering = $0 }
        .help(agent.tmuxSession)
        .contextMenu {
            Button("Restart") { appState.restartAgent(agent) }
            Button("Rename…") {
                renameText = agent.title ?? preset.name
                renameRequested = true
            }
            if let primary = appState.selectedAgent, primary.id != agent.id {
                Button(appState.splitAgentID == agent.id ? "Close Split View" : "Open Side-by-Side") {
                    appState.toggleSplit(with: agent)
                }
            }
            Divider()
            Button("Move Left") { appState.moveAgent(agent, by: -1) }
                .disabled(!appState.canMoveAgent(agent, by: -1))
            Button("Move Right") { appState.moveAgent(agent, by: 1) }
                .disabled(!appState.canMoveAgent(agent, by: 1))
            Divider()
            Button("Kill Agent", role: .destructive) { appState.killAgent(agent) }
        }
        .alert("Rename Agent", isPresented: $renameRequested) {
            TextField("Name", text: $renameText)
            Button("Save") { appState.store.renameAgent(agent, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var statusColor: Color {
        switch status {
        case .running: return .green
        case .exited: return .red
        case .unknown: return .gray
        }
    }
}
