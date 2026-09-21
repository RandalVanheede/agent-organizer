import SwiftUI

struct DetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let agent = appState.selectedAgent, let folder = appState.store.folder(agent.folderID), let tmux = appState.tmux {
            Group {
                if let secondary = appState.splitAgent {
                    HSplitView {
                        AgentPane(agent: agent, folder: folder, tmux: tmux)
                        AgentPane(agent: secondary, folder: folder, tmux: tmux)
                    }
                } else {
                    AgentPane(agent: agent, folder: folder, tmux: tmux)
                }
            }
            .navigationTitle(agent.title ?? appState.store.preset(for: agent.presetID).name)
        } else if let folder = appState.selectedFolder {
            FolderPlaceholderView(folder: folder)
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
            fontSize: appState.store.terminalFontSize
        )
        .id(agent.id)
    }
}

private struct FolderPlaceholderView: View {
    @Environment(AppState.self) private var appState
    let folder: Folder

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(folder.displayName)
                .font(.title3.weight(.semibold))
            Text("No agent selected yet.")
                .foregroundStyle(.secondary)
            Button("New Agent…") {
                appState.newAgentPopoverFolderID = folder.id
            }
            .popover(isPresented: Binding(
                get: { appState.newAgentPopoverFolderID == folder.id },
                set: { if !$0 { appState.newAgentPopoverFolderID = nil } }
            )) {
                NewAgentPopoverView(folder: folder)
            }
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
            Text("Select a folder or agent")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
