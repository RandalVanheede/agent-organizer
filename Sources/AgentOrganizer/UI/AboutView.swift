import SwiftUI

/// About window, dressed like the app icon: aubergine surface, lavender
/// type, and the icon's `>_` prompt typing the tagline once on open.
/// Always dark — it's the brand surface, not a themed panel.
struct AboutView: View {
    static let windowID = "about"
    @Environment(AppState.self) private var appState
    @Environment(AppUpdater.self) private var updater

    private enum Palette {
        static let deep = Color(red: 0x1E / 255, green: 0x14 / 255, blue: 0x28 / 255)     // #1E1428
        static let plum = Color(red: 0x2A / 255, green: 0x1D / 255, blue: 0x3A / 255)     // #2A1D3A
        static let glow = Color(red: 0x6B / 255, green: 0x4A / 255, blue: 0x8E / 255)     // #6B4A8E
        static let lavender = Color(red: 0xC9 / 255, green: 0xA7 / 255, blue: 0xF0 / 255) // #C9A7F0
        static let lilac = Color(red: 0xE9 / 255, green: 0xDD / 255, blue: 0xF7 / 255)   // #E9DDF7
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 104, height: 104)
                .shadow(color: Palette.glow.opacity(0.6), radius: 24)
                .padding(.top, 34)

            Text("Agent Organizer")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Palette.lilac)
                .padding(.top, 14)

            PromptTagline(color: Palette.lavender)
                .padding(.top, 8)
                .padding(.horizontal, 28)

            AgentCensus(textColor: Palette.lilac.opacity(0.85))
                .padding(.top, 22)

            Rectangle()
                .fill(Palette.lavender.opacity(0.15))
                .frame(height: 1)
                .padding(.horizontal, 36)
                .padding(.vertical, 22)

            versionAndUpdates
            links
                .padding(.top, 18)
                .padding(.bottom, 26)
        }
        .frame(width: 420)
        .background {
            ZStack {
                LinearGradient(colors: [Palette.plum, Palette.deep], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Palette.glow.opacity(0.55), .clear], center: UnitPoint(x: 0.5, y: 0.12),
                               startRadius: 0, endRadius: 220)
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .tint(Palette.lavender)
    }

    private var versionAndUpdates: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("Version \(BuildInfo.version) (\(BuildInfo.build))")
                if let commit = BuildInfo.commit {
                    Text(commit)
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Palette.lavender.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                        .help("Commit this build was made from")
                }
            }
            .font(.callout)
            .foregroundStyle(Palette.lilac.opacity(0.8))
            .textSelection(.enabled)

            if updater.isAvailable {
                Button("Check for Updates") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
                if let last = updater.lastCheck {
                    Text("Last checked \(last, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(Palette.lilac.opacity(0.55))
                }
            } else {
                Text("Updates aren't set up in this build.")
                    .font(.caption)
                    .foregroundStyle(Palette.lilac.opacity(0.55))
            }
        }
    }

    private var links: some View {
        HStack(spacing: 22) {
            Link("GitHub", destination: BuildInfo.repoURL)
            Link("Release notes", destination: BuildInfo.releaseNotesURL)
            Link("Report an issue", destination: BuildInfo.newIssueURL)
        }
        .font(.callout)
        .foregroundStyle(Palette.lavender)
    }
}

/// The tagline as a shell prompt, typed out once (instantly under Reduce
/// Motion), ending on a block cursor like the icon's `>_`.
private struct PromptTagline: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0
    private static let text = "every project a tab, every agent a session that never dies"

    var body: some View {
        // Full text reserves the final layout so nothing reflows while typing.
        ZStack(alignment: .topLeading) {
            line(Self.text).hidden()
            line(String(Self.text.prefix(shown)))
        }
        .accessibilityElement()
        .accessibilityLabel(Self.text)
        .task {
            guard !reduceMotion else { shown = Self.text.count; return }
            try? await Task.sleep(for: .milliseconds(350))
            while shown < Self.text.count {
                shown += 1
                try? await Task.sleep(for: .milliseconds(28))
            }
        }
    }

    private func line(_ typed: String) -> some View {
        (Text("> ").foregroundStyle(color.opacity(0.6))
            + Text(typed).foregroundStyle(color)
            + Text("\u{2588}").foregroundStyle(color.opacity(0.75)))
            .font(.system(size: 13, design: .monospaced))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Live count of your agents by status, in the app's own status shapes.
private struct AgentCensus: View {
    @Environment(AppState.self) private var appState
    let textColor: Color

    private static let order: [(AgentStatus, String)] = [(.running, "running"), (.waiting, "need you"), (.done, "finished"), (.idle, "idle"), (.exited, "ended")]

    var body: some View {
        let statuses = appState.store.agents.map { appState.agentStatuses[$0.id] ?? .unknown }
        let counts = Self.order.compactMap { status, word -> (AgentStatus, String)? in
            let n = statuses.filter { $0 == status }.count
            return n > 0 ? (status, "\(n) \(word)") : nil
        }
        HStack(spacing: 16) {
            if counts.isEmpty {
                Text("No agents open")
            } else {
                ForEach(counts, id: \.1) { status, label in
                    HStack(spacing: 6) {
                        StatusOrb(status: status, size: 7)
                        Text(label)
                    }
                }
            }
        }
        .font(.callout)
        .foregroundStyle(textColor)
    }
}
