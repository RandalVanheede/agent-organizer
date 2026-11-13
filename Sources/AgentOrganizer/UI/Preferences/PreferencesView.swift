import SwiftUI

struct PreferencesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            GeneralPreferencesView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearancePreferencesView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            PresetsPreferencesView()
                .tabItem { Label("Tools", systemImage: "terminal") }
            ShortcutsPreferencesView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 600, height: 380)
    }
}

private struct GeneralPreferencesView: View {
    @Environment(AppState.self) private var appState
    private static let sounds = ["Glass", "Tink", "Pop", "Ping", "Purr", "Blow", "Bottle", "Frog", "Funk", "Hero", "Morse", "Sosumi", "Submarine"]
    @State private var hooksInstalled = HookInstaller.isInstalled()
    @State private var hookError: String?

    var body: some View {
        let store = appState.store
        Form {
            Section("Notifications") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hooksInstalled ? "Claude Code hooks installed" : "Claude Code hooks not installed")
                        Text("Adds Notification / Stop / UserPromptSubmit hooks to ~/.claude/settings.json (a backup is kept). Agents then flag the tab, badge the Dock, and post a notification when they need you. Only fires for claude sessions started from this app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(hooksInstalled ? "Uninstall" : "Install") {
                        do {
                            if hooksInstalled { try HookInstaller.uninstall() } else { try HookInstaller.install() }
                            hookError = nil
                        } catch {
                            hookError = error.localizedDescription
                        }
                        hooksInstalled = HookInstaller.isInstalled()
                    }
                }
                if let hookError {
                    Text(hookError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Picker("Attention sound", selection: Binding(
                        get: { store.attentionSound },
                        set: { store.setAttentionSound($0) }
                    )) {
                        Text("None").tag("")
                        Divider()
                        ForEach(Self.sounds, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Play") { appState.playAttentionSound() }
                        .disabled(store.attentionSound.isEmpty)
                }
                Text("Plays when a Claude hook fires, or when any tool stops producing output for a few seconds while its tab isn't on screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

private struct ShortcutsPreferencesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("App") {
                ForEach(ShortcutAction.appActions) { row($0) }
            }
            Section {
                ForEach(ShortcutAction.terminalActions) { row($0) }
            } header: {
                Text("Terminal")
            } footer: {
                Text("Click a shortcut, then press the new keys. Esc cancels, Delete unbinds. A combination used by another action here moves to the new one; combinations owned by macOS or a fixed menu item (Quit, Copy, ⌘1–⌘9 tabs…) are refused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Restore Defaults") { appState.store.resetShortcuts() }
                    .disabled(appState.store.shortcutOverrides.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ action: ShortcutAction) -> some View {
        let store = appState.store
        return LabeledContent(action.title) {
            HStack(spacing: 6) {
                ShortcutRecorder(combo: store.shortcut(action), store: store) { store.setShortcut(action, $0) }
                Button {
                    store.setShortcut(action, action.defaultCombo == .unbound ? nil : action.defaultCombo)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Restore default (\(action.defaultCombo == .unbound ? "none" : action.defaultCombo.display))")
                .opacity(store.shortcutOverrides[action.rawValue] == nil ? 0 : 1)
            }
        }
    }
}

/// Click-to-record field. While recording, a local key monitor swallows the
/// next key-down so menus and the ⌘W monitor don't fire.
struct ShortcutRecorder: View {
    @MainActor static var isRecording = false

    let combo: KeyCombo?
    let store: Store
    let onChange: (KeyCombo?) -> Void
    @State private var monitor: Any?
    @State private var conflict: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(monitor != nil ? "Press keys…" : (combo?.display ?? "None")) {
                monitor == nil ? start() : stop()
            }
            .frame(minWidth: 110)
            if let conflict {
                Text(conflict).font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        conflict = nil
        Self.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                let mods = event.modifierFlags.intersection(KeyCombo.relevantFlags)
                if mods.isEmpty && event.keyCode == 53 {          // Esc
                    stop()
                } else if mods.isEmpty && (event.keyCode == 51 || event.keyCode == 117) { // Delete
                    onChange(nil)
                    stop()
                } else if !mods.isEmpty, let recorded = KeyCombo(event: event) {
                    if let owner = ShortcutConflicts.owner(of: recorded, store: store) {
                        conflict = "\(recorded.display) is used by \(owner)"
                        NSSound.beep()
                    } else {
                        onChange(recorded)
                    }
                    stop()
                } else {
                    NSSound.beep()  // bare keys would break typing in the terminal
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        Self.isRecording = false
    }
}

private struct AppearancePreferencesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let store = appState.store
        Form {
            Section("Window") {
                Picker("Appearance", selection: Binding(
                    get: { store.appearance },
                    set: { store.appearance = $0; store.save(); $0.apply() }
                )) {
                    Text("Follow System").tag(AppAppearance.system)
                    Text("Dark").tag(AppAppearance.dark)
                    Text("Light").tag(AppAppearance.light)
                }
                .pickerStyle(.segmented)
            }
            Section("Sidebar") {
                Picker("Show agent status as", selection: Binding(
                    get: { store.sidebarStatusStyle },
                    set: { store.sidebarStatusStyle = $0; store.save() }
                )) {
                    Text("Icons").tag(SidebarStatusStyle.icons)
                    Text("Colours").tag(SidebarStatusStyle.colors)
                    Text("Both").tag(SidebarStatusStyle.both)
                }
                Text("Colours tint folder and Agents panel rows: blue running, orange needs you, green finished, red ended. The selected row keeps the normal highlight.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Agent tabs") {
                Toggle("Animate running tabs", isOn: Binding(
                    get: { store.animateRunningTabs },
                    set: { store.animateRunningTabs = $0; store.save() }
                ))
                Text("A segment slides along the bottom of a tab while its tool works. Off, or with Reduce Motion, it\u{2019}s a static line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
