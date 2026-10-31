import AppKit
import SwiftUI
import SwiftTerm

/// Displays the cached terminal view for the selected agent. Swapping the
/// selection only re-parents the existing `LocalProcessTerminalView` into
/// this container — it never destroys and recreates it.
struct TerminalHostView: NSViewRepresentable {
    let agent: Agent?
    let cwd: URL?
    let tmux: TmuxController
    let cache: TerminalCache
    let fontSize: Double
    var remoteHost: String? = nil

    func makeNSView(context: Context) -> TerminalContainerView {
        TerminalContainerView()
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        guard let agent, let cwd else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }

        let terminalView = cache.view(for: agent, cwd: cwd, tmux: tmux, fontSize: fontSize)
        terminalView.remoteHost = remoteHost
        if terminalView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            container.addSubview(terminalView)
            terminalView.frame = container.bounds
        }
        DispatchQueue.main.async {
            terminalView.needsDisplay = true
            container.window?.makeFirstResponder(terminalView)
        }
    }
}

/// Manual frame management via `layout()` — more reliable than Auto Layout
/// constraints inside NSViewRepresentable, which SwiftUI can invalidate
/// during view identity changes (`.id()` swaps, conditional branch changes).
class TerminalContainerView: NSView {
    override func layout() {
        super.layout()
        subviews.forEach { $0.frame = bounds }
    }
}
