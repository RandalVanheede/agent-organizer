import Foundation

/// Picks up event files dropped by `ao-hook.sh` (one JSON file per Claude
/// Code hook firing) from Application Support/events. A directory watch
/// means no polling; files are deleted once handed off.
@MainActor
final class HookEventWatcher {
    struct Event {
        let pane: String        // TMUX_PANE inside the agent's pane, e.g. "%7"; "" from a remote
        /// The agent's session, known up front for remote events (OSC on its own terminal).
        var session: String? = nil
        let name: String        // "Notification" | "Stop" | "UserPromptSubmit" | "TurnEnd" | ...
        let message: String?    // Notification's / AONotify's human-readable text, if any
        let notificationType: String? // Notification's kind: permission_prompt, idle_prompt, …
        let cwd: String?
        let subagentID: String? // SubagentStart/Stop's `agent_id`
        /// The Claude Code mod sent it (not the settings hook): its `Stop` also
        /// fires on Esc and errors, with `reason`.
        let fromMod: Bool
        let reason: String?     // Stop from the mod: answer | aborted | refusal | error

        /// `{"pane","event","payload"}` as `ao-hook` writes it (remote: no pane).
        init?(_ obj: [String: Any]) {
            guard let name = obj["event"] as? String else { return nil }
            let payload = obj["payload"] as? [String: Any]
            // Trust boundary (event files, remote OSC): cap every field.
            func text(_ key: String, _ max: Int) -> String? { (payload?[key] as? String).map { String($0.prefix(max)) } }
            self.pane = String((obj["pane"] as? String ?? "").prefix(16).filter { $0.isNumber || $0 == "%" })
            self.name = String(name.prefix(32).filter(\.isLetter))
            message = text("message", 300)
            notificationType = text("notification_type", 64)
            cwd = text("cwd", 1024)
            subagentID = text("agent_id", 64).map { $0.filter { $0.isLetter || $0.isNumber || "-_".contains($0) } }
            fromMod = payload?["source"] as? String == "mod"
            reason = text("reason", 16).map { $0.filter(\.isLetter) }
        }
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
    /// Ordered by modification time (ns on APFS): names are `<seconds>-<pid>`,
    /// which sort wrong within a second.
    private func drain() {
        let fm = FileManager.default
        let key = URLResourceKey.contentModificationDateKey
        guard let files = try? fm.contentsOfDirectory(at: Self.eventsDirectory, includingPropertiesForKeys: [key]) else { return }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast
        }
        let ready: [URL] = files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { (modified($0), $0.lastPathComponent) < (modified($1), $1.lastPathComponent) }
        for file in ready {
            defer { try? fm.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = Event(obj), !event.pane.isEmpty
            else { continue }
            // Replayed after the app was closed: a stale toast or tool label is noise
            // (turn and attention events still replay, as before).
            if ["AONotify", "TurnEnd"].contains(event.name), modified(file).timeIntervalSinceNow < -60 { continue }
            onEvent?(event)
        }
    }
}
