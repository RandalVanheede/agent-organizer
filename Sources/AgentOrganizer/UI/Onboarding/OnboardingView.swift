import SwiftUI

/// Shown instead of the main window when tmux can't be located. Agent
/// Organizer relies on tmux for session persistence, so it refuses to fake
/// it with something that would die when the app quits.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("tmux couldn't start")
                .font(.title2.bold())
            // The app bundles tmux, so landing here usually means a damaged copy of the app.
            Text("Agent Organizer uses tmux to keep your agents running after the app closes. The copy of tmux inside the app is missing or broken. Reinstall Agent Organizer to fix it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)

            VStack(alignment: .leading, spacing: 6) {
                Text("Or install tmux with Homebrew, and the app will use that:")
                    .font(.callout)
                Text("brew install tmux")
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            Button("Recheck") {
                appState.recheckTmux()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
