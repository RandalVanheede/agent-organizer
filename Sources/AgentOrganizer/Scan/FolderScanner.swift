import Foundation

/// Detects whether a folder is a git repo, a container of repos, or neither —
/// by reading the filesystem directly (never shelling out to `git`).
struct FolderScanner {
    static let skippedNames: Set<String> = [
        "node_modules", "vendor", ".build", ".git", "Pods", ".venv", "venv",
        "dist", "build", ".next", "target", "DerivedData", ".cache"
    ]

    static func detectKind(at url: URL, scanDepth: Int) -> FolderKind {
        if isGitRoot(url) {
            return .repo
        }
        let repos = findRepos(under: url, depth: max(scanDepth, 1))
        return repos.isEmpty ? .plain : .container(repos: repos)
    }

    static func isGitRoot(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path)
    }

    static func findRepos(under root: URL, depth: Int) -> [SubRepo] {
        var results: [SubRepo] = []
        scan(root: root, current: root, remainingDepth: depth, results: &results)
        return results.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private static func scan(root: URL, current: URL, remainingDepth: Int, results: inout [SubRepo]) {
        guard remainingDepth > 0 else { return }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: current,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in children {
            guard let isDir = try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir else { continue }
            let name = child.lastPathComponent
            if skippedNames.contains(name) { continue }
            if isGitRoot(child) {
                results.append(SubRepo(relativePath: relativePath(of: child, from: root), branch: readBranch(at: child)))
                continue // a repo's own internals aren't scanned further
            }
            scan(root: root, current: child, remainingDepth: remainingDepth - 1, results: &results)
        }
    }

    private static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = url.standardizedFileURL.path
        guard childPath.hasPrefix(rootPath) else { return url.lastPathComponent }
        var rel = String(childPath.dropFirst(rootPath.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    /// Reads the current branch (or short SHA if detached) straight from
    /// `.git/HEAD`, following `gitdir:` redirects for worktrees/submodules.
    static func readBranch(at repoURL: URL) -> String? {
        let dotGit = repoURL.appendingPathComponent(".git")
        var headURL = dotGit.appendingPathComponent("HEAD")

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir), !isDir.boolValue {
            guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
                  let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
            else { return nil }
            let pathPart = line.replacingOccurrences(of: "gitdir:", with: "").trimmingCharacters(in: .whitespaces)
            let resolved = pathPart.hasPrefix("/")
                ? URL(fileURLWithPath: pathPart)
                : repoURL.appendingPathComponent(pathPart).standardizedFileURL
            headURL = resolved.appendingPathComponent("HEAD")
        }

        guard let head = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        }
        return trimmed.count >= 7 ? String(trimmed.prefix(7)) : nil
    }
}
