import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installCommandWMonitor()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            HookLog.write("notification authorization granted=\(granted) error=\(error?.localizedDescription ?? "none") bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
        }
    }

    /// The Kill Agent shortcut (default ⌘W) must never mean "Close Window".
    /// SwiftUI's stock File › Close claims ⌘W inconsistently, and an
    /// NSApplication subclass can't intercept it — the SwiftUI lifecycle
    /// ignores `NSPrincipalClass` (NSApp is SwiftUI's own `AppKitApplication`).
    /// A local monitor runs before menu/window key-equivalent dispatch;
    /// returning nil swallows the key. Only the Settings window keeps plain
    /// ⌘W = close, and nothing is intercepted while a shortcut is recorded.
    private func installCommandWMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let swallow: Bool = MainActor.assumeIsolated {
                guard !ShortcutRecorder.isRecording else { return false }
                if let key = NSApp.keyWindow, key.identifier?.rawValue.contains("Settings") == true {
                    guard KeyCombo(event: event) == KeyCombo(key: "w", modifiers: .command) else { return false }
                    key.performClose(nil)
                    return true
                }
                // A sheet (Quick Open, New Agent) is in front: don't kill the agent behind it.
                if NSApp.keyWindow?.sheetParent != nil { return false }
                guard let appState = self.appState,
                      appState.store.shortcut(.killAgent)?.matches(event) == true else { return false }
                if let agent = appState.selectedAgent { appState.killAgent(agent) }
                return true
            }
            return swallow ? nil : event
        }
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
        appState?.finalizePendingKills()
        if let appState, appState.store.killAgentsOnQuit {
            for agent in appState.store.agents {
                appState.tmux?.killSession(agent.tmuxSession)
            }
        }
        return .terminateNow
    }
}
