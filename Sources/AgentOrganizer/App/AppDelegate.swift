import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show banners even while the app is frontmost (the agent may be in a
    /// different folder than the one on screen).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking a notification jumps to that agent's tab.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let idString = response.notification.request.content.userInfo["agentID"] as? String,
              let id = UUID(uuidString: idString) else { return }
        await MainActor.run { self.appState?.selectAgent(id: id) }
    }

    /// Only handles the optional "kill agents on quit" preference. Default is
    /// off, so quitting never touches tmux sessions — they are separate
    /// processes on their own server and simply keep running.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let appState, appState.store.killAgentsOnQuit {
            for agent in appState.store.agents {
                appState.tmux?.killSession(agent.tmuxSession)
            }
        }
        return .terminateNow
    }
}
