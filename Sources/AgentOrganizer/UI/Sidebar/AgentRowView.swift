import SwiftUI

struct AgentRowView: View {
    @Environment(AppState.self) private var appState
    let agent: Agent

    private var preset: AgentPreset { appState.store.preset(for: agent.presetID) }
    private var status: AgentStatus { appState.agentStatuses[agent.id] ?? .unknown }
    private var folder: Folder? { appState.store.folder(agent.folderID) }
    private var subRepoBranch: String? {
        folder?.subRepos.first { $0.relativePath == agent.relativeCwd }?.branch
    }
    private var displayTitle: String {
        agent.title ?? appState.liveTitle(for: agent) ?? preset.name
    }

    var body: some View {
        @Bindable var appState = appState
        HStack(spacing: 8) {
            Image(systemName: preset.icon)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .lineLimit(1)
                if !agent.relativeCwd.isEmpty {
                    HStack(spacing: 4) {
                        Text(agent.relativeCwd)
                        if let branch = subRepoBranch {
                            Text("· \(branch)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer()
            statusDot
        }
        .contextMenu {
            Button("Restart") { appState.restartAgent(agent) }
            Button("Rename…") { renameRequested = true }
            Divider()
            Button("Kill Agent", role: .destructive) { appState.killAgent(agent) }
        }
        .alert("Rename Agent", isPresented: $renameRequested) {
            TextField("Name", text: $renameText)
            Button("Save") { appState.store.renameAgent(agent, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { renameText = agent.title ?? preset.name }
    }

    @State private var renameRequested = false
    @State private var renameText = ""

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(color(for: status))
            .frame(width: 6, height: 6)
    }

    private func color(for status: AgentStatus) -> Color {
        switch status {
        case .running: return .green
        case .exited: return .red
        case .unknown: return .gray
        }
    }
}
