import SwiftUI

/// Flat "folder → agents" list, A‑Z by folder name. No repo-level nesting:
/// a container folder (one with sub-repos) is still a single section here.
struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        List(selection: $appState.selection) {
            ForEach(appState.store.sortedFolders()) { folder in
                Section {
                    let agents = appState.store.agents(in: folder.id)
                    if agents.isEmpty {
                        Text("No agents yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(agents) { agent in
                            AgentRowView(agent: agent)
                                .tag(SidebarSelection.agent(agent.id))
                        }
                        .onMove { source, destination in
                            appState.moveAgents(in: folder.id, fromOffsets: source, toOffset: destination)
                        }
                    }
                } header: {
                    FolderHeaderView(folder: folder)
                }
            }

            if !appState.orphanSessions.isEmpty {
                Section("Unmanaged Sessions") {
                    ForEach(appState.orphanSessions) { orphan in
                        OrphanSessionRowView(orphan: orphan)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.presentAddFolderPanel()
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .help("Add Folder…")
            }
        }
        .overlay {
            if appState.store.folders.isEmpty {
                EmptySidebarView()
            }
        }
    }
}

private struct EmptySidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No folders yet")
                .foregroundStyle(.secondary)
            Button("Add Folder…") {
                appState.presentAddFolderPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
