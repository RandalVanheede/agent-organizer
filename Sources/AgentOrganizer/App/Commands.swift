import SwiftUI

struct AppCommands: Commands {
    var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Folder…") {
                appState.presentAddFolderPanel()
            }
            .keyboardShortcut(appState.store.shortcut(.addFolder)?.keyboardShortcut)

            Button("Add Remote Folder…") {
                appState.presentAddRemoteFolderPanel()
            }

            Button("New Agent…") {
                appState.requestNewAgentPopover()
            }
            .keyboardShortcut(appState.store.shortcut(.newAgent)?.keyboardShortcut)
            .disabled(!appState.canCreateNewAgent)

            Button("New Shell") {
                appState.newShellInSelectedFolder()
            }
            .keyboardShortcut(appState.store.shortcut(.newShell)?.keyboardShortcut)
            .disabled(!appState.canCreateNewAgent)

            Divider()

            // ⌘W (default) belongs to "Kill Agent" (Agent menu); SwiftUI drops
            // the stock Close item's shortcut when another command claims ⌘W,
            // so the window gets an explicit shortcut (default ⇧⌘W) instead.
            Button("Close Window") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut(appState.store.shortcut(.closeWindow)?.keyboardShortcut)
        }

        CommandMenu("Agent") {
            Button("Restart") {
                if let agent = appState.selectedAgent {
                    appState.restartAgent(agent)
                }
            }
            .keyboardShortcut(appState.store.shortcut(.restartAgent)?.keyboardShortcut)
            .disabled(appState.selectedAgent == nil)

            Divider()

            Button("Next Tab") { appState.selectAdjacentAgent(by: 1) }
                .keyboardShortcut(appState.store.shortcut(.nextTab)?.keyboardShortcut)
            Button("Previous Tab") { appState.selectAdjacentAgent(by: -1) }
                .keyboardShortcut(appState.store.shortcut(.previousTab)?.keyboardShortcut)

            Button("Next Folder") { appState.selectAdjacentFolder(by: 1) }
                .keyboardShortcut(appState.store.shortcut(.nextFolder)?.keyboardShortcut)
            Button("Previous Folder") { appState.selectAdjacentFolder(by: -1) }
                .keyboardShortcut(appState.store.shortcut(.previousFolder)?.keyboardShortcut)

            Divider()

            ForEach(1...9, id: \.self) { n in
                Button("Tab \(n)") { appState.selectAgentAtIndex(n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command])
            }

            Divider()

            // Kills the current agent (default ⌘W). The key itself is handled
            // by AppDelegate's event monitor; this shortcut is for the menu display.
            Button("Kill Agent") {
                if let agent = appState.selectedAgent {
                    appState.killAgent(agent)
                }
            }
            .keyboardShortcut(appState.store.shortcut(.killAgent)?.keyboardShortcut)
            .disabled(appState.selectedAgent == nil)
        }
    }
}
