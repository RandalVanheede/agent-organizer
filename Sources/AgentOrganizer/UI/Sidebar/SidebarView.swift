import SwiftUI

/// Folders only, A‑Z, behaving like vertical tabs: selecting one opens its
/// canvas (agent tabs + terminal) on the right. Agents are never nested here.
struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List(selection: Binding(
            get: { appState.selectedFolderID },
            set: { appState.selectFolder($0) }
        )) {
            Section("Folders") {
                ForEach(appState.store.sortedFolders()) { folder in
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
