import SwiftUI

/// Folders only, A‑Z, behaving like vertical tabs: selecting one opens its
/// canvas (agent tabs + terminal) on the right. Agents are never nested here.
struct SidebarView: View {
    @Environment(AppState.self) private var appState

    private var visibleFolders: [Folder] { appState.sidebarFolders }

    var body: some View {
        List(selection: Binding(
            get: { appState.selectedFolderID },
            set: { appState.selectFolder($0) }
        )) {
            Section("Folders") {
                ForEach(visibleFolders) { folder in
                    FolderRowView(folder: folder)
                        .tag(folder.id)
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
                Menu {
                    Button("Add Remote Folder…") { appState.presentAddRemoteFolderPanel() }
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                } primaryAction: {
                    appState.presentAddFolderPanel()
                }
                .help("Add Folder… (hold for Remote)")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !appState.store.folders.isEmpty {
                Picker("Show", selection: Binding(
                    get: { appState.store.sidebarOpenAgentsOnly },
                    set: { appState.store.setSidebarOpenAgentsOnly($0) }
                )) {
                    Text("Show all").tag(false)
                    Text("Open agents only").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
            }
        }
        .overlay {
            if appState.store.folders.isEmpty {
                EmptySidebarView()
            } else if visibleFolders.isEmpty {
                Text("No folders with open agents")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
