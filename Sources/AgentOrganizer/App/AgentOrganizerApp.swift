import SwiftUI

@main
struct AgentOrganizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @State private var updater = AppUpdater()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    appDelegate.appState = appState
                    appState.startStatusPolling()
                }
        }
        .commands {
            AppCommands(appState: appState, updater: updater)
        }

        Window("About Agent Organizer", id: AboutView.windowID) {
            AboutView()
                .environment(appState)
                .environment(updater)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Settings {
            PreferencesView()
                .environment(appState)
        }
    }
}
