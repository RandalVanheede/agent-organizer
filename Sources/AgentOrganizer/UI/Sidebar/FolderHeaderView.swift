import SwiftUI

struct FolderHeaderView: View {
    @Environment(AppState.self) private var appState
    let folder: Folder

    private var isSelected: Bool { appState.selection == .folder(folder.id) }

    var body: some View {
        @Bindable var appState = appState
        HStack(spacing: 6) {
            Image(systemName: kindIcon)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(folder.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                .lineLimit(1)
            if let branch = folder.rootBranch {
                Text(branch)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            Button {
                appState.newAgentPopoverFolderID = folder.id
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
            .help("New Agent…")
            .popover(isPresented: Binding(
                get: { appState.newAgentPopoverFolderID == folder.id },
                set: { if !$0 { appState.newAgentPopoverFolderID = nil } }
            )) {
                NewAgentPopoverView(folder: folder)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selection = .folder(folder.id)
        }
        .contextMenu {
            Button("New Agent…") { appState.newAgentPopoverFolderID = folder.id }
            Button("Rescan") { appState.rescan(folder) }
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
