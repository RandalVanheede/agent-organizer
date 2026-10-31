import SwiftUI

/// The canvas for the selected folder: agent tabs across the top, the active
/// agent's terminal below (optionally split with a second one).
struct DetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let folder = appState.selectedFolder, let tmux = appState.tmux {
            VStack(spacing: 0) {
                AgentTabBar(folder: folder)
                if let agent = appState.selectedAgent {
                    if let secondary = appState.splitAgent {
                        HSplitView {
                            AgentPane(agent: agent, folder: folder, tmux: tmux)
                            AgentPane(agent: secondary, folder: folder, tmux: tmux)
                        }
                    } else {
                        AgentPane(agent: agent, folder: folder, tmux: tmux)
                    }
                } else {
                    NoAgentsPlaceholder(folder: folder)
                }
            }
            .navigationTitle(folder.displayName)
            .navigationSubtitle(appState.selectedAgent.map { $0.title ?? appState.store.preset(for: $0.presetID).name } ?? "")
        } else {
            ContentUnavailableFallback()
        }
    }
}

/// One agent's terminal, wrapped so it can appear either full-size or as
/// one half of an `HSplitView` without duplicating the host-view wiring.
private struct AgentPane: View {
    @Environment(AppState.self) private var appState
    let agent: Agent
    let folder: Folder
    let tmux: TmuxController

    var body: some View {
        TerminalHostView(
            agent: agent,
            cwd: agent.resolvedCwd(folderPath: folder.path),
            tmux: tmux,
            cache: appState.cache,
            fontSize: appState.store.terminalFontSize,
            remoteHost: folder.host
        )
        .id(agent.id)
    }
}

private struct NoAgentsPlaceholder: View {
    @Environment(AppState.self) private var appState
    let folder: Folder

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(folder.displayName)
                .font(.title3.weight(.semibold))
            Text("No agents in this folder yet.")
                .foregroundStyle(.secondary)
            Button("New Agent…") {
                appState.newAgentPopoverFolderID = folder.id
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ContentUnavailableFallback: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Select a folder")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
