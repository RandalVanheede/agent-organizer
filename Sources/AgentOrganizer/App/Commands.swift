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
        }

        CommandMenu("Agent") {
            Button("Restart") {
                if let agent = appState.selectedAgent {
                    appState.restartAgent(agent)
                }
            }
            .disabled(appState.selectedAgent == nil)

            Button("Kill Agent") {
                if let agent = appState.selectedAgent {
                    appState.killAgent(agent)
                }
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
            .disabled(appState.selectedAgent == nil)
        }
    }
}
