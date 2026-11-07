import AppKit
import SwiftUI

/// In-app notification banners that need no system permission: floating,
/// non-activating panels stacked in the top-right of the main screen. Used
/// when `UNUserNotificationCenter` refuses us — macOS's notification daemon
/// only accepts Apple-issued code signatures, and this app is built locally
/// with a self-signed one. Click → jump to the agent. Auto-dismiss after a
/// few seconds.
@MainActor
final class ToastCenter {
    static let shared = ToastCenter()

    private var panels: [NSPanel] = []
    private let width: CGFloat = 340
    private let margin: CGFloat = 14
    private let spacing: CGFloat = 8

    func show(title: String, body: String, icon: String = "sparkles", onClick: @escaping () -> Void) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 64),
            styleMask: [.nonactivatingPanel, .borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false

        var dismissed = false
        let dismiss: () -> Void = { [weak self, weak panel] in
            guard !dismissed, let panel else { return }
            dismissed = true
            self?.remove(panel)
        }

        let view = ToastView(title: title, message: body, icon: icon) {
            dismiss()
            onClick()
        } onClose: {
            dismiss()
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = panel.contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        // Size to fit the text.
        let fitting = hosting.fittingSize
        panel.setContentSize(NSSize(width: width, height: max(56, fitting.height)))

        panels.append(panel)
        layout()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            dismiss()
        }
    }

    private func remove(_ panel: NSPanel) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                self.panels.removeAll { $0 === panel }
                self.layout()
            }
        })
    }

    private func layout() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        var y = visible.maxY - margin
        for panel in panels.reversed() { // newest on top
            let h = panel.frame.height
            let frame = NSRect(x: visible.maxX - width - margin, y: y - h, width: width, height: h)
            panel.setFrame(frame, display: true, animate: false)
            y -= h + spacing
        }
    }
}

private struct ToastView: View {
    let title: String
    let message: String
    let icon: String
    let onClick: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
        .onHover { hovering = $0 }
        .frame(width: 340)
    }
}
