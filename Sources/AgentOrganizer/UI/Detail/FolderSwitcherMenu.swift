import SwiftUI

/// Title-bar dropdown shown while the sidebar is collapsed: jump between
/// folders that have open agents without bringing the sidebar back.
struct FolderSwitcherMenu: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let folders = appState.store.foldersWithAgents()
        Menu {
            if folders.isEmpty {
                Text("No folders with open agents")
            } else {
                Picker("Folder", selection: Binding(
                    get: { appState.selectedFolderID },
                    set: { appState.selectFolder($0) }
                )) {
                    ForEach(folders) { folder in
                        Label(itemTitle(folder), systemImage: appState.folderNeedsAttention(folder.id) ? "bell.badge" : "folder")
                            .tag(Optional(folder.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            Label(appState.selectedFolder?.displayName ?? "Folders", systemImage: "folder")
                .labelStyle(.titleAndIcon)
        }
        .help("Switch Folder")
    }

    private func itemTitle(_ folder: Folder) -> String {
        "\(folder.displayName) (\(appState.store.agents(in: folder.id).count))"
    }
}
