import SwiftUI

struct NewAgentPopoverView: View {
    @Environment(AppState.self) private var appState
    let folder: Folder

    @State private var presetID: String = AgentPreset.claude.id
    @State private var cwdChoice: CwdChoice = .root

    private enum CwdChoice: Hashable {
        case root
        case subRepo(String)
    }

    var body: some View {
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

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    appState.newAgentPopoverFolderID = nil
                }
                Button("Create") {
                    let preset = appState.store.preset(for: presetID)
                    let relativeCwd: String
                    switch cwdChoice {
                    case .root: relativeCwd = ""
                    case .subRepo(let path): relativeCwd = path
                    }
                    appState.createAgent(folder: folder, preset: preset, relativeCwd: relativeCwd)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 260)
    }
}
