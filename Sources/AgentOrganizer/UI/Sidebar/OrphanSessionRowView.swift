import SwiftUI

/// A tmux session on this app's socket that isn't tracked as an agent —
/// almost always left behind on purpose by "Remove Folder, Keep Agents
/// Running". Shown rather than hidden so nothing running is ever forgotten;
/// the user can adopt it back into a folder or kill it explicitly.
struct OrphanSessionRowView: View {
    @Environment(AppState.self) private var appState
    let orphan: OrphanSession

    private var matchingFolder: Folder? {
        orphan.matchingFolderID.flatMap { appState.store.folder($0) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.square.dashed")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(orphan.name)
                    .lineLimit(1)
                if let cwd = orphan.cwd {
                    Text(cwd)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .contextMenu {
            if let matchingFolder {
                Button("Adopt into \(matchingFolder.displayName)") {
                    appState.adopt(orphan, into: matchingFolder)
                }
            }
            Button("Kill Session", role: .destructive) {
                appState.killOrphan(orphan)
            }
        }
        .help(matchingFolder != nil
            ? "Right-click to adopt into \(matchingFolder!.displayName) or kill it."
            : "Right-click to kill it. Its folder isn't in your sidebar, so it can't be adopted.")
    }
}
