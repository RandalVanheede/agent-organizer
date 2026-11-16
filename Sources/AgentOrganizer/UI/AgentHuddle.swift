import AppKit
import SwiftUI

/// Floating "Agent Huddle": a non-activating panel (bottom-right, clear of
/// the top-right toasts) listing working / waiting / finished agents while
/// Agent Organizer is in the background. Off by default (Preferences ›
/// Notifications). Hidden whenever the app is active, so it never covers the
/// window it duplicates. Draggable; keeps its position for the session.
@MainActor
final class AgentHuddle {
    static let shared = AgentHuddle()

    private var panel: NSPanel?
    private weak var appState: AppState?
    /// Closed with × — stays hidden until the app is next deactivated.
    private var dismissed = false
    /// Corner the panel was last placed in; a preference change re-places it, a drag doesn't.
    private var placedCorner: HuddleCorner?

    func start(_ appState: AppState) {
        guard self.appState == nil else { return }
        self.appState = appState
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.dismissed = false; self.refresh() }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }
        track()
    }

    /// Re-evaluates on every change to what `shouldShow` reads (setting, statuses).
    private func track() {
        withObservationTracking { refresh() } onChange: {
            Task { @MainActor in self.track() }
        }
    }

    private var shouldShow: Bool {
        guard let appState, appState.store.agentHuddle, !dismissed, !(NSApp?.isActive ?? true) else { return false }
        return !Self.agents(appState).isEmpty
    }

    private func refresh() {
        guard shouldShow, let appState else { panel?.orderOut(nil); return }
        let panel = panel ?? makePanel(appState)
        if placedCorner != appState.store.huddleCorner { place(panel, in: appState.store.huddleCorner) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func place(_ panel: NSPanel, in corner: HuddleCorner) {
        placedCorner = corner
        guard let v = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let size = panel.frame.size, m: CGFloat = 14
        panel.setFrameOrigin(NSPoint(x: corner.isLeft ? v.minX + m : v.maxX - size.width - m,
                                     y: corner.isTop ? v.maxY - size.height - m : v.minY + m))
    }

    private func makePanel(_ appState: AppState) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: HuddleView.width, height: 80),
            styleMask: [.nonactivatingPanel, .borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HuddleView(onClose: { [weak self] in
            self?.dismissed = true
            self?.refresh()
        }, onResize: { [weak self, weak panel] size in
            // Grow away from the chosen corner's edges, so the list never runs off-screen.
            guard let self, let panel, size.height > 0, panel.frame.size != size else { return }
            let f = panel.frame, corner = self.placedCorner ?? .bottomRight
            panel.setFrame(NSRect(x: corner.isLeft ? f.minX : f.maxX - size.width,
                                  y: corner.isTop ? f.maxY - size.height : f.minY,
                                  width: size.width, height: size.height), display: true)
        }).environment(appState))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Same set as the sidebar's Agents panel: needs you, then working, then done.
    static func agents(_ appState: AppState) -> [Agent] {
        let order: [AgentStatus] = [.waiting, .running, .done]
        return appState.store.agents
            .filter { order.contains(appState.agentStatuses[$0.id] ?? .unknown) }
            .sorted { order.firstIndex(of: appState.agentStatuses[$0.id]!)! < order.firstIndex(of: appState.agentStatuses[$1.id]!)! }
    }
}

private struct HuddleView: View {
    static let width: CGFloat = 320
    @Environment(AppState.self) private var appState
    let onClose: () -> Void
    let onResize: (CGSize) -> Void
    @State private var collapsed = false

    var body: some View {
        let agents = AgentHuddle.agents(appState)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(agents.contains { appState.agentStatuses[$0.id] == .waiting } ? AgentStatus.waiting.color : AgentStatus.running.color)
                    .frame(width: 7, height: 7)
                Text("Agent Huddle").font(.subheadline.weight(.semibold))
                Text("\(agents.count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                iconButton(collapsed ? "chevron.down" : "chevron.up", help: collapsed ? "Expand" : "Collapse") { collapsed.toggle() }
                iconButton("xmark", help: "Hide until next time", action: onClose)
            }
            .padding(.horizontal, 4)
            .background(WindowDragArea())
            if !collapsed {
                ForEach(agents) { HuddleRow(agent: $0) }
            }
        }
        .padding(8)
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 12).fill(Chrome.background))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Chrome.cardBorder))
        .fixedSize() // report the ideal size, not whatever the panel currently is
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onResize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct HuddleRow: View {
    @Environment(AppState.self) private var appState
    let agent: Agent
    @State private var isHovering = false

    var body: some View {
        let status = appState.agentStatuses[agent.id] ?? .done
        let folderName = appState.store.folder(agent.folderID)?.displayName ?? ""
        Button {
            appState.selectAgent(id: agent.id) // activates the app → huddle hides
        } label: {
            HStack(spacing: 10) {
                FolderAvatar(name: folderName, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    (Text(folderName).fontWeight(.semibold)
                     + Text(" · " + appState.displayTitle(for: agent)).foregroundColor(.secondary))
                        .lineLimit(1)
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(status.color)
                }
                Spacer(minLength: 4)
                StatusOrb(status: status, size: 8).frame(width: 12)
            }
            .font(.callout)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isHovering ? Color.primary.opacity(0.06) : .clear))
            .background(RoundedRectangle(cornerRadius: 8).fill(Chrome.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Chrome.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("\(status.label) — click to open")
    }
}

/// Drags the window from the huddle's header. `isMovableByWindowBackground`
/// does nothing here: SwiftUI's hosting view claims the mouse-down.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}
