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
            Text("tmux not found")
                .font(.title2.bold())
            Text("Agent Organizer uses tmux to keep your agent sessions running even after the app is closed.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)

            VStack(alignment: .leading, spacing: 6) {
                Text("Install it with Homebrew:")
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
