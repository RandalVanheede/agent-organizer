import AppKit

/// Principal class (see Info.plist `NSPrincipalClass`). Exists for one
/// reason: ⌘W must mean "Kill Agent", not "Close Window". SwiftUI's stock
/// File › Close item claims ⌘W inconsistently across launches, and AppKit
/// dispatches a key equivalent to the *first* menu item holding it (File
/// precedes Agent). Stripping the stock item's shortcut right before the
/// event is dispatched makes Agent › Kill Agent the only claimant.
@objc(AOApplication)
final class AOApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            stripStockCloseShortcut()
        }
        super.sendEvent(event)
    }

    private func stripStockCloseShortcut() {
        guard let file = mainMenu?.items.first(where: { $0.title == "File" })?.submenu else { return }
        for item in file.items
        where item.title == "Close" && item.keyEquivalent == "w" && item.keyEquivalentModifierMask == [.command] {
            item.keyEquivalent = ""
        }
    }
}
