import SwiftUI

/// The canvas for the selected folder: agent tabs across the top, the active
/// agent's terminal below (optionally split with a second one).
struct DetailView: View {
    @Environment(AppState.self) private var appState
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        if let folder = appState.selectedFolder, let tmux = appState.tmux {
            VStack(spacing: 0) {
                AgentTabBar(folder: folder, columnVisibility: $columnVisibility)
                if let agent = appState.selectedAgent {
                    if let secondary = appState.splitAgent {
                        HSplitView {
                            AgentPane(agent: agent, folder: folder, tmux: tmux, isSplit: true)
                            AgentPane(agent: secondary, folder: folder, tmux: tmux, isSplit: true)
                        }
                    } else {
                        AgentPane(agent: agent, folder: folder, tmux: tmux, isSplit: false)
                    }
                } else {
                    NoAgentsPlaceholder(folder: folder)
                }
                StatusBar(folder: folder)
            }
            .background(Chrome.background)
            .ignoresSafeArea(.container, edges: .top) // tab bar sits in the (hidden) title bar row
            .navigationTitle(folder.displayName)
            .navigationSubtitle(appState.selectedAgent.map { $0.title ?? appState.store.preset(for: $0.presetID).name } ?? "")
        } else {
            ContentUnavailableFallback()
        }
    }
}

/// One agent's terminal, wrapped so it can appear either full-size or as
/// one half of an `HSplitView` without duplicating the host-view wiring.
private struct AgentPane: View {
    @Environment(AppState.self) private var appState
    let agent: Agent
    let folder: Folder
    let tmux: TmuxController
    /// The header and focus outline only earn their space when two panes need telling apart;
    /// a lone pane sits right under its own tab, and its cwd is in the status bar.
    let isSplit: Bool

    private var cwd: URL { agent.resolvedCwd(folderPath: folder.path) }

    var body: some View {
        // Card: header + terminal inset by padding (not clipped: clipping an
        // NSView-backed terminal to a rounded shape is unreliable).
        VStack(spacing: 0) {
            if isSplit {
                HStack(spacing: 6) {
                    Image(systemName: appState.store.preset(for: agent.presetID).icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(appState.displayTitle(for: agent))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(displayPath(cwd, in: folder))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4)
                    StatusOrb(status: appState.agentStatuses[agent.id] ?? .unknown)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
            }
            TerminalHostView(
                agent: agent,
                cwd: cwd,
                tmux: tmux,
                cache: appState.cache,
                remoteHost: folder.host
            )
            .id("\(agent.id)-\(appState.terminalEpochs[agent.id] ?? 0)")
            .overlay {
                if appState.agentStatuses[agent.id] == .exited {
                    SessionEndedView(agent: agent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, isSplit ? 0 : 6)
            .padding(.bottom, 6)
        }
        .background(Chrome.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
            isSplit && appState.selectedAgent?.id == agent.id ? Color.accentColor.opacity(0.7) : Chrome.cardBorder))
        .padding(8)
    }
}

/// `~/…` locally; remote paths as-is (a tilde would mean the Mac's home).
private func displayPath(_ url: URL, in folder: Folder) -> String {
    folder.isRemote ? url.path : (url.path as NSString).abbreviatingWithTildeInPath
}

/// Footer: where you are (host · branch · agents) and the Quick Open hint.
private struct StatusBar: View {
    @Environment(AppState.self) private var appState
    let folder: Folder

    private var branch: String? {
        guard let agent = appState.selectedAgent, !agent.relativeCwd.isEmpty else { return folder.rootBranch }
        return folder.subRepos.first { $0.relativePath == agent.relativeCwd }?.branch
    }

    var body: some View {
        let count = appState.store.agents(in: folder.id).count
        HStack(spacing: 14) {
            // Everything but the cwd gets priority 1, so the cwd truncates first
            // (a negative priority on it would lose to the Spacer and always show "…").
            Label(folder.host ?? "This Mac", systemImage: folder.isRemote ? "server.rack" : "desktopcomputer")
                .layoutPriority(1)
            if let agent = appState.selectedAgent {
                Label(displayPath(agent.resolvedCwd(folderPath: folder.path), in: folder), systemImage: "folder")
                    .truncationMode(.head)
            }
            if let branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .layoutPriority(1)
            }
            Label(count == 1 ? "1 agent" : "\(count) agents", systemImage: "circle.fill")
                .labelStyle(DotLabelStyle())
                .layoutPriority(1)
            Spacer()
            if let shortcut = appState.store.shortcut(.quickOpen) {
                Text("\(shortcut.display) open folder")
                    .layoutPriority(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .overlay(alignment: .top) { Chrome.hairline.frame(height: 1) }
    }
}

/// Tiny dot instead of a full-size SF Symbol for the agent count.
private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 5))
            configuration.title
        }
    }
}

/// Replaces a dead terminal with what you can do about it. The old output
/// stays visible, dimmed, behind the card.
private struct SessionEndedView: View {
    @Environment(AppState.self) private var appState
    let agent: Agent

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.35))
            VStack(spacing: 10) {
                Image(systemName: "stop.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Session ended")
                    .font(.title3.weight(.semibold))
                Text("\(appState.displayTitle(for: agent)) is no longer running. Restart it here, or close the tab.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 300)
                HStack {
                    Button("Close Tab") { appState.killAgent(agent) }
                    // No default-action key: the dead terminal holds focus, and
                    // a split view could show two of these cards.
                    Button("Restart") { appState.restartAgent(agent) }
                }
                .padding(.top, 4)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct NoAgentsPlaceholder: View {
    @Environment(AppState.self) private var appState
    let folder: Folder

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(folder.displayName)
                .font(.title3.weight(.semibold))
            Text("No agents in this folder yet. Start one:")
                .foregroundStyle(.secondary)
            // Same one-click buttons as the tab bar (with the sub-repo menu where there is one).
            if appState.store.presets.isEmpty {
                Button("New Agent…") { appState.newAgentPopoverFolderID = folder.id }
                    .keyboardShortcut(.defaultAction)
            } else {
                HStack(spacing: 8) {
                    ForEach(appState.store.presets) { preset in
                        NewAgentButton(folder: folder, preset: preset, large: true)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ContentUnavailableFallback: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Select a folder")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
