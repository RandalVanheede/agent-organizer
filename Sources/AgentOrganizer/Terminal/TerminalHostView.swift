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

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let agent, let cwd else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }

        let terminalView = cache.view(for: agent, cwd: cwd, tmux: tmux)
        if terminalView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            terminalView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(terminalView)
            NSLayoutConstraint.activate([
                terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                terminalView.topAnchor.constraint(equalTo: container.topAnchor),
                terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        DispatchQueue.main.async {
            container.window?.makeFirstResponder(terminalView)
        }
    }
}
