import SwiftUI

struct PreferencesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var store = appState.store
        TabView {
            Form {
                Toggle("Kill all agents when Agent Organizer quits", isOn: Binding(
                    get: { store.killAgentsOnQuit },
                    set: { store.killAgentsOnQuit = $0; store.save() }
                ))
                Text("Off by default: agents keep running in tmux after you quit, exactly like closing a terminal tab you've detached from.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Stepper(value: Binding(
                    get: { store.terminalFontSize },
                    set: { appState.setTerminalFontSize($0) }
                ), in: 9...24, step: 1) {
                    Text("Terminal font size: \(Int(store.terminalFontSize))pt")
                }
            }
            .padding(20)
            .tabItem { Text("General") }

            PresetsPreferencesView()
                .tabItem { Text("Tools") }
        }
        .frame(width: 460, height: 320)
    }
}

private struct PresetsPreferencesView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedPresetID: String?

    var body: some View {
        HSplitView {
            List(appState.store.presets, selection: $selectedPresetID) { preset in
                Label(preset.name, systemImage: preset.icon).tag(preset.id)
            }
            .frame(minWidth: 150)

            if let preset = appState.store.presets.first(where: { $0.id == selectedPresetID }) {
                PresetEditorView(preset: preset)
            } else {
                Text("Select a tool to edit it.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let preset = appState.store.addPreset(name: "New Tool", command: "", resumeCommand: nil, icon: "terminal")
                    selectedPresetID = preset.id
                } label: {
                    Label("Add Tool", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard let preset = appState.store.presets.first(where: { $0.id == selectedPresetID }) else { return }
                    if appState.store.removePreset(preset) {
                        selectedPresetID = nil
                    }
                } label: {
                    Label("Remove Tool", systemImage: "minus")
                }
                .disabled(selectedPresetID == nil)
            }
        }
        .padding(.top, 20)
    }
}

private struct PresetEditorView: View {
    @Environment(AppState.self) private var appState
    let preset: AgentPreset

    @State private var name: String = ""
    @State private var command: String = ""
    @State private var resumeCommand: String = ""

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Launch command", text: $command)
            TextField("Resume command (optional)", text: $resumeCommand)
            Text("Resume runs instead of the launch command when you pick \"Restart\" on an agent using this tool — e.g. \"claude --continue\".")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { load(preset) }
        .onChange(of: preset) { _, new in load(new) }
        .onChange(of: name) { _, _ in save() }
        .onChange(of: command) { _, _ in save() }
        .onChange(of: resumeCommand) { _, _ in save() }
    }

    private func load(_ preset: AgentPreset) {
        name = preset.name
        command = preset.command
        resumeCommand = preset.resumeCommand ?? ""
    }

    private func save() {
        var updated = preset
        updated.name = name
        updated.command = command
        updated.resumeCommand = resumeCommand.isEmpty ? nil : resumeCommand
        appState.store.updatePreset(updated)
    }
}
