import SwiftUI

/// One vertical "tab" in the sidebar. Agents are not listed here any more —
/// they live as horizontal tabs on the canvas — so the row carries a count
/// badge and one status orb summarising its agents (exited > waiting >
/// running > idle; nothing when the folder has no agents).
struct FolderRowView: View {
    @Environment(AppState.self) private var appState
    let folder: Folder

    private var agentCount: Int { appState.store.agents(in: folder.id).count }

    var body: some View {
        HStack(spacing: 8) {
            FolderAvatar(name: folder.displayName)
            // Name and branch on one line, branch muted (Herdr-style).
            (Text(folder.displayName).fontWeight(.semibold)
             + Text(folder.rootBranch.map { "  " + $0 } ?? "").font(.caption).foregroundColor(.secondary))
                .lineLimit(1)
                .help(folder.isRemote ? "\(folder.host ?? "") — \(kindLabel)" : kindLabel)
            Spacer(minLength: 4)
            if appState.store.sidebarStatusStyle.showsIcon, let status = appState.folderStatus(folder.id) {
                StatusOrb(status: status, size: 6)
            }
            if agentCount > 0 {
                Text("\(agentCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .contextMenu {
            Button("New Agent…") { appState.newAgentPopoverFolderID = folder.id }
            Button("Rescan") { appState.rescan(folder) }
            if !folder.isRemote {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder.path])
                }
            }
            Divider()
            Button("Remove Folder", role: .destructive) { appState.requestRemoveFolder(folder) }
        }
    }

    private var kindLabel: String {
        switch folder.kind {
        case .repo: return "Git repository"
        case .container: return "Folder with \(folder.subRepos.count) repositories"
        case .plain: return "Folder"
        }
    }
}
