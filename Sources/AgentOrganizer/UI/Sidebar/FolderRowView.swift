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
            Image(systemName: kindIcon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.displayName)
                    .lineLimit(1)
                if let branch = folder.rootBranch {
                    Text(branch)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let status = appState.folderStatus(folder.id) {
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
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([folder.path])
            }
            Divider()
            Button("Remove Folder", role: .destructive) { appState.requestRemoveFolder(folder) }
        }
    }

    private var kindIcon: String {
        switch folder.kind {
        case .repo: return "folder.fill.badge.gearshape"
        case .container: return "folder.fill"
        case .plain: return "folder"
        }
    }
}
