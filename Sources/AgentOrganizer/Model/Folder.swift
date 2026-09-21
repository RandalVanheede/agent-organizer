import Foundation

/// A repo discovered inside a container folder (used only to populate the
/// "start agent in..." cwd picker and to show a branch badge — it never
/// becomes its own sidebar entry).
struct SubRepo: Codable, Hashable, Identifiable {
    var id: String { relativePath }
    var relativePath: String
    var branch: String?
}

enum FolderKind: Codable, Hashable {
    case repo
    case container(repos: [SubRepo])
    case plain
}

/// One sidebar entry. A folder is opened once by the user and stays a single
/// entry regardless of whether it's a git repo, a bag of repos, or neither.
struct Folder: Identifiable, Codable, Hashable {
    let id: UUID
    var path: URL
    var displayName: String
    var kind: FolderKind
    var scanDepth: Int

    init(id: UUID = UUID(), path: URL, scanDepth: Int = 1) {
        self.id = id
        self.path = path
        self.displayName = path.lastPathComponent
        self.kind = .plain
        self.scanDepth = scanDepth
    }

    /// Repos available for the cwd picker, empty for `.plain`/`.repo` (repo root is the only cwd there).
    var subRepos: [SubRepo] {
        if case let .container(repos) = kind { return repos }
        return []
    }
}
