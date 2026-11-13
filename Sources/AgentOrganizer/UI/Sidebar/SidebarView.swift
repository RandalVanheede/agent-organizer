import SwiftUI

/// Folders only, A‑Z, behaving like vertical tabs: selecting one opens its
/// canvas (agent tabs + terminal) on the right. Agents are never nested here.
struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @Binding var columnVisibility: NavigationSplitViewVisibility

    private var visibleFolders: [Folder] { appState.sidebarFolders }

    /// Folders grouped by machine, this Mac first, then remote hosts A‑Z.
    private var hostGroups: [(host: String?, folders: [Folder])] {
        let grouped = Dictionary(grouping: visibleFolders, by: \.host)
        return grouped.keys.sorted { ($0 ?? "") < ($1 ?? "") }.map { ($0, grouped[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Replaces the title bar: traffic lights on the left, actions on the right.
            HStack(spacing: 2) {
                Spacer()
                Menu {
                    Button("Add Folder…") { appState.presentAddFolderPanel() }
                    Button("Add Remote Folder…") { appState.presentAddRemoteFolderPanel() }
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 24, height: 24)
                .help("Add Folder…")
                .accessibilityLabel("Add Folder")
                SidebarToggleButton(columnVisibility: $columnVisibility)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            folderList
            AgentsPanel()
        }
        .background(Chrome.background)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var folderList: some View {
        List(selection: Binding(
            get: { appState.selectedFolderID },
            set: { appState.selectFolder($0) }
        )) {
            // Header is a plain (untagged, unselectable) row, not a section header:
            // sidebar section headers grow a hover collapse caret that shoves the
            // filter button left, and .collapsible(false) doesn't suppress it.
            Section {
                FoldersHeader()
                let groups = hostGroups
                ForEach(groups, id: \.host) { group in
                    if groups.count > 1 { HostHeader(host: group.host) } // same caret reason
                    ForEach(group.folders) { folder in
                        FolderRowView(folder: folder)
                            .tag(folder.id)
                            .statusTint(appState.folderStatus(folder.id), style: appState.store.sidebarStatusStyle)
                    }
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
        .scrollContentBackground(.hidden)
        .listStyle(.sidebar)
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

/// "This Mac" / remote host label above its folders.
private struct HostHeader: View {
    let host: String?

    var body: some View {
        Label(host ?? "This Mac", systemImage: host == nil ? "desktopcomputer" : "server.rack")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.top, 4)
    }
}

/// Bottom of the sidebar: every agent that isn't just sitting idle, from any
/// folder, grouped Needs you / Working / Done. Click a row to jump to it.
private struct AgentsPanel: View {
    @Environment(AppState.self) private var appState

    private static let groups: [(title: String, status: AgentStatus)] = [
        ("Needs you", .waiting), ("Working", .running), ("Done", .done),
    ]

    var body: some View {
        let buckets = Self.groups.map { group in
            (group, appState.store.agents.filter { appState.agentStatuses[$0.id] == group.status }
                .sorted { since($0) < since($1) })
        }.filter { !$0.1.isEmpty }
        if !buckets.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Chrome.hairline.frame(height: 1)
                Text("Agents")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(buckets, id: \.0.title) { group, agents in
                            Text("\(group.title)  \(agents.count)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(group.status.color)
                                .padding(.horizontal, 8)
                                .padding(.top, 6)
                            ForEach(agents) { agent in
                                AgentPanelRow(agent: agent, status: group.status, since: since(agent))
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A blocked agent ages from when it asked; others from their last status change.
    private func since(_ agent: Agent) -> TimeInterval {
        appState.attention[agent.id]?.since ?? appState.statusSince[agent.id] ?? Date().timeIntervalSince1970
    }
}

private struct AgentPanelRow: View {
    @Environment(AppState.self) private var appState
    let agent: Agent
    let status: AgentStatus
    let since: TimeInterval

    @State private var isHovering = false

    var body: some View {
        let folder = appState.store.folder(agent.folderID)
        let style = appState.store.sidebarStatusStyle
        Button {
            appState.selectAgent(agent)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: appState.store.preset(for: agent.presetID).icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                (Text(folder?.displayName ?? "").fontWeight(.semibold)
                 + Text(" · " + appState.displayTitle(for: agent)).foregroundColor(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let host = folder?.host {
                    Text(host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                // Coarse on purpose: a per-second clock would redraw the sidebar constantly.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Self.age(since: since, now: context.date))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                StatusOrb(status: status, size: 6)
                    .frame(width: 10)
                    .opacity(style.showsIcon ? 1 : 0)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5).fill(
                    style.showsColor ? status.color.opacity(0.15)
                        : (isHovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("\(status.label) — click to open")
    }

    static func age(since: TimeInterval, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince1970 - since) / 60
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}
