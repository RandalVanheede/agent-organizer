import Foundation

/// Installs the Claude Code hook that lets agents tell the app when they
/// need attention. Two pieces: a copy of `ao-hook.sh` in Application
/// Support (stable path even if the .app moves), and hook entries merged
/// into `~/.claude/settings.json`. Existing hooks are left untouched; a
/// one-time backup of settings.json is written next to it.
enum HookInstaller {
    static let events = ["Notification", "Stop", "UserPromptSubmit"]

    static var scriptURL: URL {
        Store.appSupportDirectory().appendingPathComponent("bin/ao-hook", isDirectory: false)
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    enum InstallError: LocalizedError {
        case bundledScriptMissing
        case settingsUnreadable
        var errorDescription: String? {
            switch self {
            case .bundledScriptMissing: return "ao-hook.sh is missing from the app bundle."
            case .settingsUnreadable: return "~/.claude/settings.json exists but isn't valid JSON."
            }
        }
    }

    /// True when every event has a hook entry pointing at our script.
    static func isInstalled() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path),
              let hooks = try? readHooks() else { return false }
        return events.allSatisfy { event in
            (hooks[event] as? [[String: Any]])?.contains(where: groupIsOurs) ?? false
        }
    }

    static func install() throws {
        guard let bundled = Bundle.main.url(forResource: "ao-hook", withExtension: "sh") else {
            throw InstallError.bundledScriptMissing
        }
        let fm = FileManager.default
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: scriptURL.path) { try fm.removeItem(at: scriptURL) }
        try fm.copyItem(at: bundled, to: scriptURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var root = try readSettings()
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        for event in events {
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            if !groups.contains(where: groupIsOurs) {
                groups.append(["hooks": [["type": "command", "command": command(for: event)]]])
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try writeSettings(root)
    }

    static func uninstall() throws {
        var root = try readSettings()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for event in events {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups.removeAll(where: groupIsOurs)
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        root["hooks"] = hooks
        try writeSettings(root)
        try? FileManager.default.removeItem(at: scriptURL)
    }

    // MARK: - Helpers

    private static func command(for event: String) -> String {
        // Defensive like other tools' hooks: never break claude if the app
        // (and its script) is gone.
        "if [ -x '\(scriptURL.path)' ]; then '\(scriptURL.path)' \(event); else cat >/dev/null 2>&1 || :; fi"
    }

    private static func groupIsOurs(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains("/Agent Organizer/bin/ao-hook") == true }
    }

    private static func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data), let dict = obj as? [String: Any] else {
            throw InstallError.settingsUnreadable
        }
        return dict
    }

    private static func readHooks() throws -> [String: Any] {
        (try readSettings()["hooks"] as? [String: Any]) ?? [:]
    }

    private static func writeSettings(_ root: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = settingsURL.appendingPathExtension("ao-backup")
        if fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: settingsURL, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
