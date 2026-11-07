import SwiftUI

/// ⌘P — type to jump to any folder, whatever the sidebar filter hides.
/// ↑/↓ move, ↩ opens, Esc closes.
struct QuickOpenView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    private var results: [Folder] {
        let withAgents = Set(appState.store.agents.map(\.folderID))
        return QuickOpenRanking.rank(appState.store.sortedFolders(), query: query, withAgents: withAgents)
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            TextField("Open folder", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onSubmit { open(results) }
                .onKeyPress(.downArrow) { move(1, in: results); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
                .onExitCommand { dismiss() }
            Divider()
            // Fixed height: a sheet sized to its first content (e.g. the
            // short "no match" text) won't grow back for later results.
            Group {
            if results.isEmpty {
                Text(appState.store.folders.isEmpty ? "No folders added yet." : "No folders match \u{201C}\(query)\u{201D}.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, folder in
                                QuickOpenRow(folder: folder, isHighlighted: index == highlighted)
                                    .id(folder.id)
                                    .onTapGesture {
                                        highlighted = index
                                        open(results)
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: highlighted) {
                        guard results.indices.contains(highlighted) else { return }
                        proxy.scrollTo(results[highlighted].id)
                    }
                }
            }
            }
            .frame(height: 340, alignment: .top)
        }
        .frame(width: 480)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { highlighted = 0 }
    }

    private func move(_ offset: Int, in results: [Folder]) {
        guard !results.isEmpty else { return }
        highlighted = min(max(highlighted + offset, 0), results.count - 1)
    }

    private func open(_ results: [Folder]) {
        guard results.indices.contains(highlighted) else { return }
        appState.selectFolder(results[highlighted].id)
        dismiss()
    }
}

private struct QuickOpenRow: View {
    @Environment(AppState.self) private var appState
    let folder: Folder
    let isHighlighted: Bool

    var body: some View {
        let agentCount = appState.store.agents(in: folder.id).count
        HStack(spacing: 10) {
            Image(systemName: folder.isRemote ? "network" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.displayName).lineLimit(1)
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let status = appState.folderStatus(folder.id) {
                StatusOrb(status: status, size: 6)
            }
            if agentCount > 0 {
                Text(agentCount == 1 ? "1 agent" : "\(agentCount) agents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? Color.accentColor.opacity(0.2) : .clear)
        )
        .contentShape(Rectangle())
    }

    private var location: String {
        if let host = folder.host { return "\(host):\(folder.path.path)" }
        return (folder.path.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Folder matching for Quick Open: name prefix > name substring > name
/// fuzzy (letters in order) > path substring. An empty query lists folders
/// with open agents first. Ties keep the incoming (alphabetical) order.
enum QuickOpenRanking {
    static func rank(_ folders: [Folder], query: String, withAgents: Set<Folder.ID>) -> [Folder] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let scored: [(folder: Folder, score: Int)] = folders.compactMap { folder in
            if q.isEmpty { return (folder, withAgents.contains(folder.id) ? 1 : 0) }
            return score(name: folder.displayName, path: folder.path.path, query: q).map { (folder, $0) }
        }
        // Stable sort: enumerated offset breaks ties.
        return scored.enumerated()
            .sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }
            .map(\.element.folder)
    }

    static func score(name: String, path: String, query q: String) -> Int? {
        let n = name.lowercased()
        if n.hasPrefix(q) { return 4 }
        if n.contains(q) { return 3 }
        if isSubsequence(q, of: n) { return 2 }
        if path.lowercased().contains(q) { return 1 }
        return nil
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var rest = Substring(haystack)
        for c in needle {
            guard let i = rest.firstIndex(of: c) else { return false }
            rest = rest[rest.index(after: i)...]
        }
        return true
    }

    /// Debug-build self-check (no test target in this package).
    static func selfCheck() {
        assert(score(name: "agent-organizer", path: "/p/agent-organizer", query: "agent") == 4)
        assert(score(name: "my-agent", path: "/p/my-agent", query: "agent") == 3)
        assert(score(name: "agent-organizer", path: "/p", query: "aorg") == 2)
        assert(score(name: "web", path: "/Users/me/clients/acme/web", query: "acme") == 1)
        assert(score(name: "web", path: "/p/web", query: "zzz") == nil)
        let a = Folder(path: URL(fileURLWithPath: "/p/alpha")), b = Folder(path: URL(fileURLWithPath: "/p/beta"))
        assert(rank([a, b], query: "", withAgents: [b.id]).map(\.id) == [b.id, a.id])
        assert(rank([a, b], query: "a", withAgents: []).map(\.id) == [a.id, b.id])
    }
}
