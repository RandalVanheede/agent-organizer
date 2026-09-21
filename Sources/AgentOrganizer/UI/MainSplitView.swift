import SwiftUI

struct MainSplitView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
        } detail: {
            DetailView()
        }
        .sheet(item: Binding(
            get: { appState.newAgentPopoverFolderID.flatMap { appState.store.folder($0) } },
            set: { newValue in appState.newAgentPopoverFolderID = newValue?.id }
        )) { folder in
            NewAgentPopoverView(folder: folder)
        }
        .alert(
            "Remove \"\(appState.folderPendingRemoval?.displayName ?? "")\"?",
            isPresented: Binding(
                get: { appState.folderPendingRemoval != nil },
                set: { if !$0 { appState.folderPendingRemoval = nil } }
            ),
            presenting: appState.folderPendingRemoval
        ) { folder in
            Button("Remove, Keep Agents Running", role: .none) {
                appState.removeFolder(folder, killAgents: false)
            }
            Button("Remove and Kill Agents", role: .destructive) {
                appState.removeFolder(folder, killAgents: true)
            }
            Button("Cancel", role: .cancel) {
                appState.folderPendingRemoval = nil
            }
        } message: { folder in
            Text("This folder has \(appState.store.agents(in: folder.id).count) agent(s). They keep running in tmux unless you choose to kill them.")
        }
    }
}
