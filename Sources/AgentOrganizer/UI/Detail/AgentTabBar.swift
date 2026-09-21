import SwiftUI

/// Horizontal tabs along the top of a folder's canvas — one per agent (each
/// with an X that kills it instantly), plus one "+ <tool>" button per preset
/// on the right. Mirrors the sidebar's vertical tabs.
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
            Divider().frame(height: 18).padding(.horizontal, 4)
            HStack(spacing: 4) {
                ForEach(appState.store.presets) { preset in
                    NewAgentButton(folder: folder, preset: preset)
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: 34)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

/// One button per tool. Plain folders create an agent at the root
/// instantly; folders with sub-repos offer root + each sub-repo in a menu.
private struct NewAgentButton: View {
    @Environment(AppState.self) private var appState
    let folder: Folder
    let preset: AgentPreset

    var body: some View {
        if folder.subRepos.isEmpty {
            Button {
                appState.createAgent(folder: folder, preset: preset, relativeCwd: "")
            } label: {
                label
            }
            .buttonStyle(.plain)
            .help("New \(preset.name) agent")
        } else {
            Menu {
                Button("in \(folder.displayName)") {
                    appState.createAgent(folder: folder, preset: preset, relativeCwd: "")
                }
                Divider()
                ForEach(folder.subRepos) { repo in
                    Button(repo.branch.map { "\(repo.relativePath) · \($0)" } ?? repo.relativePath) {
                        appState.createAgent(folder: folder, preset: preset, relativeCwd: repo.relativePath)
                    }
                }
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New \(preset.name) agent…")
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.caption2.weight(.semibold))
            Image(systemName: preset.icon)
                .font(.caption)
            Text(preset.name)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
    }
}

private struct AgentTabView: View {
    @Environment(AppState.self) private var appState
    let agent: Agent
    let isActive: Bool

    @State private var isHovering = false
    @State private var closeHovering = false
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
                // Close = kill, instantly, no confirmation (user's call).
                Button {
                    appState.killAgent(agent)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.primary.opacity(closeHovering ? 0.15 : 0)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { closeHovering = $0 }
                .opacity(isActive || isHovering ? 1 : 0)
                .help("Kill agent")
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
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
