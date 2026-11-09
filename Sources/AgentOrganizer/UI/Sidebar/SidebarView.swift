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
            let needsYou = appState.needsYouAgents
            if !needsYou.isEmpty {
                Section("Needs you") {
                    ForEach(needsYou) { agent in
                        AttentionAgentRow(agent: agent)
                    }
                }
            }

            // Header is a plain (untagged, unselectable) row, not a section header:
            // sidebar section headers grow a hover collapse caret that shoves the
            // filter button left, and .collapsible(false) doesn't suppress it.
            Section {
                FoldersHeader()
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
        .overlay {
            if appState.store.folders.isEmpty {
                EmptySidebarView()
            } else if visibleFolders.isEmpty {
                Text(appState.store.shortcut(.quickOpen).map { "No folders with open agents. Press \($0.display) to open any folder." }
                     ?? "No folders with open agents.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false) // keep the header's filter toggle clickable
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

/// Section title plus the "only folders with open agents" filter toggle.
private struct FoldersHeader: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let filtered = appState.store.sidebarOpenAgentsOnly
        HStack {
            Text(filtered ? "Folders with agents" : "Folders")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if !appState.store.folders.isEmpty {
                Button {
                    appState.store.setSidebarOpenAgentsOnly(!filtered)
                } label: {
                    Image(systemName: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(filtered ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(filtered ? "Show all folders" : "Show only folders with open agents")
                .accessibilityLabel(filtered ? "Show all folders" : "Show only folders with open agents")
            }
        }
    }
}

/// One agent that needs you, from any folder. Click to jump to it.
private struct AttentionAgentRow: View {
    @Environment(AppState.self) private var appState
    let agent: Agent

    var body: some View {
        Button {
            appState.selectAgent(agent)
        } label: {
            HStack(spacing: 8) {
                StatusOrb(status: .waiting, size: 6)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.displayTitle(for: agent))
                        .lineLimit(1)
                    Text(appState.store.folder(agent.folderID)?.displayName ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let since = appState.attention[agent.id]?.since {
                    // Coarse on purpose: a per-second clock would redraw the sidebar constantly.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.age(since: since, now: context.date))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Blocked on your answer — click to open")
    }

    static func age(since: TimeInterval, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince1970 - since) / 60
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}
