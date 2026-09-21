import Foundation

/// Watches a folder's root directory plus every known repo's `.git/HEAD`
/// (its own, or each sub-repo's) for changes, and calls back debounced —
/// so branch switches, new commits' checkouts, and new/removed sub-repos
/// are picked up without polling the filesystem.
@MainActor
final class FolderWatcher {
    private struct Watch {
        var sources: [DispatchSourceFileSystemObject]
    }

    private var watches: [Folder.ID: Watch] = [:]
    private var debounceTimers: [Folder.ID: Timer] = [:]

    var onChange: ((Folder.ID) -> Void)?

    func watch(_ folder: Folder) {
        stopWatching(folder.id)

        var paths = [folder.path.path]
        switch folder.kind {
        case .repo:
            paths.append(folder.path.appendingPathComponent(".git/HEAD").path)
        case .container(let repos):
            for repo in repos {
                paths.append(folder.path.appendingPathComponent(repo.relativePath).appendingPathComponent(".git/HEAD").path)
            }
        case .plain:
            break
        }

        var sources: [DispatchSourceFileSystemObject] = []
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .extend, .attrib, .link],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.scheduleDebouncedChange(for: folder.id)
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            sources.append(source)
        }
        watches[folder.id] = Watch(sources: sources)
    }

    func stopWatching(_ folderID: Folder.ID) {
        watches[folderID]?.sources.forEach { $0.cancel() }
        watches.removeValue(forKey: folderID)
        debounceTimers[folderID]?.invalidate()
        debounceTimers.removeValue(forKey: folderID)
    }

    func stopAll() {
        for id in Array(watches.keys) { stopWatching(id) }
    }

    private func scheduleDebouncedChange(for folderID: Folder.ID) {
        debounceTimers[folderID]?.invalidate()
        debounceTimers[folderID] = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.onChange?(folderID) }
        }
    }
}
