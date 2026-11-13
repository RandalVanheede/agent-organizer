import AppKit
import SwiftTerm

/// Holds one live `LocalProcessTerminalView` per agent for the lifetime of
/// the app run. Views are created lazily on first attach and are never
/// evicted while the agent still exists — switching folders/agents in the
/// sidebar must not lose scrollback or detach the underlying tmux client.
///
/// Quitting the app tears these views (and their `tmux attach` child
/// processes) down, but the tmux *server* and its sessions live on outside
/// this process, so nothing the user was running is lost.
@MainActor
final class TerminalCache {
    private var views: [Agent.ID: AOTerminalView] = [:]
    private var delegates: [Agent.ID: TerminalAttachDelegate] = [:]
    /// Source of the terminal key bindings; set by `AppState`.
    weak var store: Store?

    func view(for agent: Agent, cwd: URL, tmux: TmuxController) -> AOTerminalView {
        if let existing = views[agent.id] {
            return existing
        }

        let view = AOTerminalView(frame: .zero)
        view.sessionName = agent.tmuxSession
        view.store = store
        applySettings(to: view)
        view.applyTheme(for: NSApp.effectiveAppearance)
        let delegate = TerminalAttachDelegate()
        view.processDelegate = delegate
        delegates[agent.id] = delegate

        // Never create the session here: this runs inside a SwiftUI update,
        // and a stale agent (just killed) would resurrect as an orphan.
        // Sessions are created by `AppState.createAgent` only.
        let args = ["-S", tmux.socketPath] + (tmux.confPath.map { ["-f", $0] } ?? []) + ["attach-session", "-t", agent.tmuxSession]
        view.startProcess(executable: tmux.tmuxBinary, args: args)

        views[agent.id] = view
        return view
    }

    /// Pushes the Terminal preferences to every live view (new ones get them in `view(for:)`).
    func applySettings() {
        views.values.forEach(applySettings(to:))
    }

    private func applySettings(to view: AOTerminalView) {
        guard let store else { return }
        let size = store.terminalFontSize
        view.font = store.terminalFontFamily
            .flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) }
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        if view.lineSpacing != store.terminalLineSpacing { view.lineSpacing = store.terminalLineSpacing }
        view.optionAsMetaKey = store.optionAsMeta
        view.getTerminal().setCursorStyle(CursorStyle(tagName: store.terminalCursorStyle) ?? .blinkBlock)
    }

    /// Installed fixed-pitch font families, for the Preferences picker.
    static let monospacedFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter {
        NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: 13)?.isFixedPitch == true
    }

    func hasView(for agentID: Agent.ID) -> Bool {
        views[agentID] != nil
    }

    func exitedAgents() -> Set<Agent.ID> {
        Set(delegates.filter { $0.value.terminated }.keys)
    }

    /// Only called when the user explicitly kills/removes an agent.
    func discard(_ agentID: Agent.ID) {
        views.removeValue(forKey: agentID)
        delegates.removeValue(forKey: agentID)
    }
}

/// Tracks whether the attach client (and therefore, presumably, the tmux
/// session) has died, without doing anything else — no auto-restart, no hiding.
final class TerminalAttachDelegate: LocalProcessTerminalViewDelegate {
    private(set) var terminated = false

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        terminated = true
    }
}

/// Terminal.app-style word/line navigation (bindings from
/// `ShortcutAction.terminalActions`). SwiftTerm's own keyDown can't be
/// overridden (not `open`), but AppKit offers every key event to
/// `performKeyEquivalent` first, so intercept them there.
final class AOTerminalView: LocalProcessTerminalView {
    weak var store: Store?
    /// The agent's tmux session (set at creation); keys the opener token.
    var sessionName: String?
    /// ssh host when this agent lives in a remote folder (set by the host view).
    var remoteHost: String? {
        didSet {
            guard remoteHost != nil, oldValue == nil else { return }
            getTerminal().registerOscHandler(code: RemoteSession.openerOSC) { [weak self] payload in
                guard let host = self?.remoteHost, let session = self?.sessionName else { return }
                let bytes = ArraySlice(Array(payload))
                DispatchQueue.main.async { RemoteSession.handleOpenRequest(bytes, host: host, session: session) }
            }
        }
    }

    /// SwiftTerm bakes colours to fixed values, so re-apply on light/dark switches.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme(for: effectiveAppearance)
    }

    /// Herdr-like look: soft grey (dark) / white (light) background matching
    /// the card, plus an ANSI palette that stays readable on each.
    func applyTheme(for appearance: NSAppearance) {
        let dark = Chrome.isDark(appearance)
        let fg = dark ? Self.hex(0xD8DADF) : Self.hex(0x1F2328)
        nativeBackgroundColor = Chrome.terminalBackground(for: appearance)
        nativeForegroundColor = fg
        caretColor = fg
        selectedTextBackgroundColor = dark ? Self.hex(0x3A4250) : Self.hex(0xC8D7F2)
        installColors(dark ? Self.darkPalette : Self.lightPalette)
    }

    private static func hex(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// black, red, green, yellow, blue, magenta, cyan, white; then the bright set.
    private static let darkPalette = palette([
        0x3B3E44, 0xE06C75, 0x98C379, 0xE5C07B, 0x7AA2F7, 0xC678DD, 0x56B6C2, 0xB4B8C0,
        0x5C6370, 0xF0838B, 0xAAD48C, 0xF0CE8F, 0x93B5FF, 0xD48FEA, 0x6CCAD5, 0xEEF0F3,
    ])
    private static let lightPalette = palette([
        0x2B2D31, 0xC0392B, 0x2E8B57, 0xB58900, 0x5A73E6, 0xA347BA, 0x1F8A99, 0x8A8F98,
        0x6B7079, 0xD9534F, 0x3FA66B, 0xC9A227, 0x7B8FF0, 0xB55FCC, 0x2AA1B3, 0xB8BCC4,
    ])

    private static func palette(_ rgb: [Int]) -> [SwiftTerm.Color] {
        rgb.map { SwiftTerm.Color(red8: UInt16($0 >> 16 & 0xFF), green8: UInt16($0 >> 8 & 0xFF), blue8: UInt16($0 & 0xFF)) }
    }

    /// Remote tabs: the remote tool can't read the Mac clipboard, so copied
    /// files / images are uploaded and their remote paths pasted instead.
    override func paste(_ sender: Any) {
        if !pasteUploadingToRemote() { super.paste(sender) }
    }

    private func pasteUploadingToRemote() -> Bool {
        guard let host = remoteHost, let items = RemoteSession.pasteboardUploads(.general) else { return false }
        RemoteSession.upload(items, to: host) { [weak self] paths in
            guard let self, !paths.isEmpty else { NSSound.beep(); return }
            let text = paths.joined(separator: " ") + " "
            self.send(txt: self.getTerminal().bracketedPasteMode ? "\u{1b}[200~\(text)\u{1b}[201~" : text)
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌃V is Claude Code's image-paste key; same upload in remote tabs.
        if event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
           event.charactersIgnoringModifiers == "v", pasteUploadingToRemote() {
            return true
        }
        guard event.type == .keyDown, let store,
              let bytes = ShortcutAction.terminalActions
                .first(where: { store.shortcut($0)?.matches(event) == true })?.terminalBytes
        else { return super.performKeyEquivalent(with: event) }
        send(bytes)
        return true
    }
}
