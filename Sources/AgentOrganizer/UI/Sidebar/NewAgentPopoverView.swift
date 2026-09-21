import SwiftUI

/// Presented as a sheet from a single place at the window root
/// (`MainSplitView`), never as a per-row `.popover` — popovers anchored
/// inside `List` section headers proved unreliable with many folders (wrong
/// anchor, wrong row, sometimes failing to present at all once a row was
/// already selected). A sheet has no anchor to get wrong.
struct NewAgentPopoverView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let folder: Folder

    @State private var presetID: String = AgentPreset.claude.id
    @State private var cwdChoice: CwdChoice = .root

    private enum CwdChoice: Hashable {
        case root
        case subRepo(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Agent")
                    .font(.title3.weight(.semibold))
                Text("in \(folder.displayName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Form {
                Picker("Tool", selection: $presetID) {
                    ForEach(appState.store.presets) { preset in
                        Label(preset.name, systemImage: preset.icon).tag(preset.id)
                    }
                }

                if !folder.subRepos.isEmpty {
                    Picker("Start in", selection: $cwdChoice) {
                        Text(folder.displayName).tag(CwdChoice.root)
                        ForEach(folder.subRepos) { repo in
                            Text(repo.relativePath).tag(CwdChoice.subRepo(repo.relativePath))
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    let preset = appState.store.preset(for: presetID)
                    let relativeCwd: String
                    switch cwdChoice {
                    case .root: relativeCwd = ""
                    case .subRepo(let path): relativeCwd = path
                    }
                    appState.createAgent(folder: folder, preset: preset, relativeCwd: relativeCwd)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
