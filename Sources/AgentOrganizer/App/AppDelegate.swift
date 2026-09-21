import AppKit

/// Only handles the optional "kill agents on quit" preference. Default is
/// off, so quitting the app never touches tmux sessions — they are separate
/// processes on their own server and simply keep running.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var appState: AppState?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let appState, appState.store.killAgentsOnQuit {
            for agent in appState.store.agents {
                appState.tmux?.killSession(agent.tmuxSession)
            }
        }
        return .terminateNow
    }
}
