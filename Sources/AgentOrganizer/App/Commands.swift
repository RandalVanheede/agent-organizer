import SwiftUI

struct AppCommands: Commands {
    var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Folder…") {
                appState.presentAddFolderPanel()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("New Agent…") {
                appState.requestNewAgentPopover()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(!appState.canCreateNewAgent)

            Divider()

            // ⌘W belongs to "Kill Agent" (Agent menu); SwiftUI drops the stock
            // Close item's shortcut when another command claims ⌘W, so the
            // window gets an explicit ⇧⌘W here instead.
            Button("Close Window") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandMenu("Agent") {
            Button("Restart") {
                if let agent = appState.selectedAgent {
                    appState.restartAgent(agent)
                }
            }
            .disabled(appState.selectedAgent == nil)

            Divider()

            Button("Next Tab") { appState.selectAdjacentAgent(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { appState.selectAdjacentAgent(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])

            Divider()

            // ⌘W kills the current agent (see File › Close Window for ⇧⌘W).
            Button("Kill Agent") {
                if let agent = appState.selectedAgent {
                    appState.killAgent(agent)
                }
            }
            .keyboardShortcut("w", modifiers: [.command])
            .disabled(appState.selectedAgent == nil)
        }
    }
}
