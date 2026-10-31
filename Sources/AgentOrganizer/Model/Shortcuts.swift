import AppKit
import SwiftUI

/// One key + modifiers. `key` is a lowercased unshifted character, or one of
/// "left"/"right"/"up"/"down"/"return". An empty key means "unbound".
struct KeyCombo: Codable, Hashable {
    var key: String
    var modifiers: UInt

    static let relevantFlags: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    static let unbound = KeyCombo(key: "", modifiers: 0)

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers.intersection(Self.relevantFlags).rawValue
    }

    init(key: String, modifiers: UInt) {
        self.key = key
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let key: String
        switch event.keyCode {
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        case 36, 76: key = "return"
        default:
            // Unshifted so ⇧⌘] records as "]" (charactersIgnoringModifiers keeps Shift).
            guard let c = event.characters(byApplyingModifiers: [])?.lowercased(), !c.isEmpty else { return nil }
            key = c
        }
        self.init(key: key, modifiers: event.modifierFlags)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    func matches(_ event: NSEvent) -> Bool { KeyCombo(event: event) == self }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        switch key {
        case "left": s += "←"
        case "right": s += "→"
        case "up": s += "↑"
        case "down": s += "↓"
        case "return": s += "↩"
        case " ": s += "Space"
        case "\t": s += "⇥"
        case "`": s += "`"
        default: s += key.uppercased()
        }
        return s
    }

    var keyboardShortcut: KeyboardShortcut? {
        let equivalent: KeyEquivalent
        switch key {
        case "": return nil
        case "left": equivalent = .leftArrow
        case "right": equivalent = .rightArrow
        case "up": equivalent = .upArrow
        case "down": equivalent = .downArrow
        case "return": equivalent = .return
        default:
            guard let c = key.first else { return nil }
            equivalent = KeyEquivalent(c)
        }
        var m: EventModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: m)
    }
}

/// Every rebindable shortcut. App actions drive menu items; terminal actions
/// are handled by `AOTerminalView` and send bytes to the pane. Terminal keys
/// win over menu items (the view sees key equivalents before the menu), so
/// `Store.setShortcut` moves a combo off whatever action held it.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case addFolder, newAgent, newShell, closeWindow
    case restartAgent, killAgent
    case nextTab, previousTab, nextFolder, previousFolder
    case wordBack, wordForward, lineStart, lineEnd, newline

    var id: String { rawValue }

    static let appActions: [ShortcutAction] = [
        .addFolder, .newAgent, .newShell, .closeWindow,
        .restartAgent, .killAgent, .nextTab, .previousTab, .nextFolder, .previousFolder,
    ]
    static let terminalActions: [ShortcutAction] = [.wordBack, .wordForward, .lineStart, .lineEnd, .newline]

    var title: String {
        switch self {
        case .addFolder: "Add Folder"
        case .newAgent: "New Agent"
        case .newShell: "New Shell"
        case .closeWindow: "Close Window"
        case .restartAgent: "Restart Agent"
        case .killAgent: "Kill Agent"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .nextFolder: "Next Folder"
        case .previousFolder: "Previous Folder"
        case .wordBack: "Word back"
        case .wordForward: "Word forward"
        case .lineStart: "Line start"
        case .lineEnd: "Line end"
        case .newline: "Newline (Claude Code)"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .addFolder: KeyCombo(key: "o", modifiers: [.command, .shift])
        case .newAgent: KeyCombo(key: "n", modifiers: .command)
        case .newShell: KeyCombo(key: "t", modifiers: .command)
        case .closeWindow: KeyCombo(key: "w", modifiers: [.command, .shift])
        case .restartAgent: .unbound
        case .killAgent: KeyCombo(key: "w", modifiers: .command)
        case .nextTab: KeyCombo(key: "]", modifiers: [.command, .shift])
        case .previousTab: KeyCombo(key: "[", modifiers: [.command, .shift])
        case .nextFolder: KeyCombo(key: "down", modifiers: .command)
        case .previousFolder: KeyCombo(key: "up", modifiers: .command)
        case .wordBack: KeyCombo(key: "left", modifiers: .option)
        case .wordForward: KeyCombo(key: "right", modifiers: .option)
        case .lineStart: KeyCombo(key: "left", modifiers: .command)
        case .lineEnd: KeyCombo(key: "right", modifiers: .command)
        case .newline: KeyCombo(key: "return", modifiers: .shift)
        }
    }

    /// Bytes a terminal action sends to the pane (nil for app actions).
    var terminalBytes: [UInt8]? {
        switch self {
        case .wordBack: [0x1b, 0x62]     // ESC b
        case .wordForward: [0x1b, 0x66]  // ESC f
        case .lineStart: [0x01]          // ^A
        case .lineEnd: [0x05]            // ^E
        case .newline: [0x1b, 0x0d]      // ESC CR
        default: nil
        }
    }
}

/// Finds who else already uses a combo, so the recorder can refuse it.
@MainActor
enum ShortcutConflicts {
    /// System-wide shortcuts that never appear in our menu bar (macOS
    /// defaults; a user may have remapped them in System Settings).
    private static let system: [(KeyCombo, String)] = [
        (KeyCombo(key: " ", modifiers: .command), "Spotlight"),
        (KeyCombo(key: " ", modifiers: [.command, .option]), "Finder search"),
        (KeyCombo(key: " ", modifiers: .control), "Switch input source"),
        (KeyCombo(key: "\t", modifiers: .command), "App Switcher"),
        (KeyCombo(key: "\t", modifiers: [.command, .shift]), "App Switcher"),
        (KeyCombo(key: "`", modifiers: .command), "Cycle windows"),
        (KeyCombo(key: "3", modifiers: [.command, .shift]), "Screenshot"),
        (KeyCombo(key: "4", modifiers: [.command, .shift]), "Screenshot"),
        (KeyCombo(key: "5", modifiers: [.command, .shift]), "Screenshot"),
        (KeyCombo(key: "q", modifiers: [.command, .control]), "Lock Screen"),
        (KeyCombo(key: "left", modifiers: .control), "Move left a space"),
        (KeyCombo(key: "right", modifiers: .control), "Move right a space"),
        (KeyCombo(key: "up", modifiers: .control), "Mission Control"),
        (KeyCombo(key: "down", modifiers: .control), "App windows"),
        (KeyCombo(key: "d", modifiers: [.command, .option]), "Show/hide Dock"),
    ]

    /// Name of the menu item or system feature owning `combo`, or nil when
    /// it is free (or held by one of our own rebindable actions — those
    /// are moved by `Store.setShortcut`).
    static func owner(of combo: KeyCombo, store: Store) -> String? {
        if ShortcutAction.allCases.contains(where: { store.shortcut($0) == combo }) { return nil }
        if let hit = system.first(where: { $0.0 == combo }) { return hit.1 }
        return NSApp.mainMenu.flatMap { menuOwner(of: combo, in: $0) }
    }

    private static func menuOwner(of combo: KeyCombo, in menu: NSMenu) -> String? {
        for item in menu.items {
            if let sub = item.submenu, let hit = menuOwner(of: combo, in: sub) { return hit }
            if let itemCombo = KeyCombo(menuItem: item), itemCombo == combo { return item.title }
        }
        return nil
    }
}

extension KeyCombo {
    /// An uppercase letter key equivalent implies Shift; arrows arrive as
    /// NSEvent function-key characters.
    init?(menuItem item: NSMenuItem) {
        guard let scalar = item.keyEquivalent.unicodeScalars.first else { return nil }
        var mods = item.keyEquivalentModifierMask
        let key: String
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: key = "left"
        case NSRightArrowFunctionKey: key = "right"
        case NSUpArrowFunctionKey: key = "up"
        case NSDownArrowFunctionKey: key = "down"
        case 0x0d, 0x03: key = "return"
        default:
            let k = item.keyEquivalent
            if k != k.lowercased() { mods.insert(.shift) }
            key = k.lowercased()
        }
        self.init(key: key, modifiers: mods)
    }
}
