import Foundation

/// Picks up event files dropped by `ao-hook.sh` (one JSON file per Claude
/// Code hook firing) from Application Support/events. A directory watch
/// means no polling; files are deleted once handed off.
@MainActor
final class HookEventWatcher {
    struct Event {
        let pane: String        // TMUX_PANE inside the agent's pane, e.g. "%7"
        let name: String        // "Notification" | "Stop" | "UserPromptSubmit" | ...
        let message: String?    // Notification's human-readable text, if any
        let cwd: String?
        let subagentID: String? // SubagentStart/Stop's `agent_id`
    }

    static var eventsDirectory: URL {
        Store.appSupportDirectory().appendingPathComponent("events", isDirectory: true)
    }

    var onEvent: ((Event) -> Void)?

    private var source: DispatchSourceFileSystemObject?

    func start() {
        let dir = Self.eventsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.drain() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        drain()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// Process every pending event file, oldest first, then remove it.
    private func drain() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.eventsDirectory, includingPropertiesForKeys: nil) else { return }
        let ready = files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in ready {
            defer { try? fm.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pane = obj["pane"] as? String, !pane.isEmpty,
                  let name = obj["event"] as? String
            else { continue }
            let payload = obj["payload"] as? [String: Any]
            onEvent?(Event(
                pane: pane,
                name: name,
                message: payload?["message"] as? String,
                cwd: payload?["cwd"] as? String,
                subagentID: payload?["agent_id"] as? String
            ))
        }
    }
}
