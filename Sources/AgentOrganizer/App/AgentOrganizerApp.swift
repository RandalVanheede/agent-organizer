import SwiftUI

@main
struct AgentOrganizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

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
            AppCommands(appState: appState)
        }
    }
}
