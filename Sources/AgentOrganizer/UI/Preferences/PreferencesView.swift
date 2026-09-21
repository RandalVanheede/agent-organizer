import SwiftUI

struct PreferencesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem { Label("General", systemImage: "gearshape") }
            PresetsPreferencesView()
                .tabItem { Label("Tools", systemImage: "terminal") }
        }
        .frame(width: 600, height: 380)
    }
}

private struct GeneralPreferencesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let store = appState.store
        Form {
            Section("Sessions") {
                Toggle("Kill all agents when Agent Organizer quits", isOn: Binding(
                    get: { store.killAgentsOnQuit },
                    set: { store.killAgentsOnQuit = $0; store.save() }
                ))
                Text("Off by default: agents keep running in tmux after you quit, like a detached terminal tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Terminal") {
                Stepper(value: Binding(
                    get: { store.terminalFontSize },
                    set: { appState.setTerminalFontSize($0) }
                ), in: 9...24, step: 1) {
                    Text("Font size: \(Int(store.terminalFontSize)) pt")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Master–detail: tool list on the left with +/− underneath, editor on the right.
private struct PresetsPreferencesView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedPresetID: String?
    @State private var removalBlocked = false

    private var selectedPreset: AgentPreset? {
        appState.store.presets.first { $0.id == selectedPresetID }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(appState.store.presets, selection: $selectedPresetID) { preset in
                    Label(preset.name, systemImage: preset.icon).tag(preset.id)
                }
                .listStyle(.inset)
                Divider()
                HStack(spacing: 0) {
                    Button {
                        let preset = appState.store.addPreset(name: "New Tool", command: "", resumeCommand: nil, icon: "terminal")
                        selectedPresetID = preset.id
                    } label: {
                        Image(systemName: "plus").frame(width: 24, height: 22)
                    }
                    .help("Add tool")
                    Divider().frame(height: 16)
                    Button {
                        guard let preset = selectedPreset else { return }
                        if appState.store.removePreset(preset) {
                            selectedPresetID = nil
                        } else {
                            removalBlocked = true
                        }
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 22)
                    }
                    .disabled(selectedPreset == nil)
                    .help("Remove tool")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .frame(width: 190)

            Divider()

            if let preset = selectedPreset {
                PresetEditorView(preset: preset)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Select a tool to edit it")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedPresetID == nil { selectedPresetID = appState.store.presets.first?.id }
        }
        .alert("Tool is in use", isPresented: $removalBlocked) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("One or more agents were created with this tool. Kill those agents first, then remove it.")
        }
    }
}

private struct PresetEditorView: View {
    @Environment(AppState.self) private var appState
    let preset: AgentPreset

    @State private var name: String = ""
    @State private var command: String = ""
    @State private var resumeCommand: String = ""

    private static let icons = [
        "sparkles", "terminal", "chevron.left.forwardslash.chevron.right",
        "brain", "cpu", "bolt", "hammer", "wand.and.stars", "cube", "leaf"
    ]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Claude Code"))
                Picker("Icon", selection: Binding(
                    get: { preset.icon },
                    set: { var p = preset; p.icon = $0; appState.store.updatePreset(p) }
                )) {
                    ForEach(Self.icons, id: \.self) { icon in
                        Image(systemName: icon).tag(icon)
                    }
                }
                .pickerStyle(.menu)
            }
            Section {
                TextField("Launch command", text: $command, prompt: Text("claude"))
                    .font(.body.monospaced())
                TextField("Resume command", text: $resumeCommand, prompt: Text("claude --continue"))
                    .font(.body.monospaced())
            } footer: {
                Text("Runs inside a fresh login shell in the folder. “Restart” on a tab kills the pane's process, then runs the resume command (or the launch command if empty). Leave the launch command empty for a plain shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { load(preset) }
        .onChange(of: preset.id) { _, _ in load(preset) }
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
        if updated != preset { appState.store.updatePreset(updated) }
    }
}
