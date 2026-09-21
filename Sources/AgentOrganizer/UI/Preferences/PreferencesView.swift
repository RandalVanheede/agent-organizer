import SwiftUI

struct PreferencesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var store = appState.store
        Form {
            Toggle("Kill all agents when Agent Organizer quits", isOn: Binding(
                get: { store.killAgentsOnQuit },
                set: { store.killAgentsOnQuit = $0; store.save() }
            ))
            Text("Off by default: agents keep running in tmux after you quit, exactly like closing a terminal tab you've detached from.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }
}
