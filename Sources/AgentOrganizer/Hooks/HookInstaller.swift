import Foundation

/// Connects Claude Code to the app, in two layers:
/// - **settings.json hooks** (every Claude Code version): `Notification` /
///   `Stop` / `UserPromptSubmit` / `SubagentStart` / `SubagentStop` entries
///   merged into `~/.claude/settings.json` (other hooks untouched; one-time
///   backup). Always installed: a mod's own classic.* hooks are skipped by
///   Claude Code's built-in plugins, so these stay the reliable source.
/// - **the `agent-organizer` plugin** (Claude Code with mods, on top): a hooks
///   module (`Resources/claude-plugin`) installed from a folder marketplace in
///   Application Support. Native events only, never duplicating the hooks: turn
///   ends with a reason (Esc, API errors), the running tool, a `notify` tool.
/// Both call the same `ao-hook` script, copied to Application Support so its
/// path survives the app moving. `refresh()` at launch tops both up, so a
/// Claude Code upgrade adds the plugin and a new app version reinstalls it.
enum HookInstaller {
    /// SubagentStart/Stop keep an agent "running" while background sub-agents
    /// work after the main turn has stopped.
    static let events = ["Notification", "Stop", "UserPromptSubmit", "SubagentStart", "SubagentStop"]
    static let pluginID = "agent-organizer@agent-organizer"
    private static let marketplaceName = "agent-organizer"

    /// `.plugin` = settings hooks plus the plugin; `.settings` = hooks only.
    enum Mode: Sendable { case plugin, settings }

    static var scriptURL: URL {
        Store.appSupportDirectory().appendingPathComponent("bin/ao-hook", isDirectory: false)
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The marketplace folder the plugin installs from. Claude Code runs a
    /// cached copy made at install time, so a changed plugin is reinstalled.
    static var pluginDirectory: URL {
        Store.appSupportDirectory().appendingPathComponent("claude-plugin", isDirectory: true)
    }

    static var bundledPluginDirectory: URL? {
        Bundle.main.url(forResource: "claude-plugin", withExtension: nil)
    }

    /// Pi (pi.dev) auto-loads extensions from here; only used when Pi is set up
    /// (`~/.pi/agent` exists), never created for people who don't use it.
    static var piExtensionURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/extensions/agent-organizer.ts")
    }

    static var bundledPiExtension: URL? {
        Bundle.main.url(forResource: "agent-organizer", withExtension: "ts", subdirectory: "pi-extension")
    }

    private static var installedPluginsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/plugins/installed_plugins.json")
    }

    enum InstallError: LocalizedError {
        case bundledScriptMissing
        case settingsUnreadable
        case cli(String)
        var errorDescription: String? {
            switch self {
            case .bundledScriptMissing: return "ao-hook.sh or the Claude Code plugin is missing from the app bundle."
            case .settingsUnreadable: return "~/.claude/settings.json exists but isn't valid JSON."
            case .cli(let message): return message
            }
        }
    }

    /// Cheap (file reads only): safe on the main thread.
    static func isInstalled() -> Bool { installedMode() != nil }

    static func installedMode() -> Mode? {
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path), settingsHooksInstalled() else { return nil }
        return pluginEnabled() ? .plugin : .settings
    }

    /// Installs or tops up both layers. Spawns `claude`, hence async; runs one
    /// at a time with `uninstall`/`refresh` (launch refresh vs a button click).
    @discardableResult
    static func install() async throws -> Mode {
        try await gate.run { try await installNow() }
    }

    static func uninstall() async throws {
        try await gate.run {
            if pluginPresent() {
                let (status, output) = await claude(["plugin", "uninstall", pluginID])
                if pluginPresent() {
                    throw InstallError.cli("claude plugin uninstall failed (status \(status)): \(output.prefix(200))")
                }
            }
            _ = await claude(["plugin", "marketplace", "remove", marketplaceName])
            try removeSettingsHooks()
            try? FileManager.default.removeItem(at: pluginDirectory)
            try? FileManager.default.removeItem(at: scriptURL)
            if isOurPiExtension() { try? FileManager.default.removeItem(at: piExtensionURL) }
        }
    }

    /// At launch: refresh the files (a new app version may ship new ones), top
    /// up the hooks, and add or reinstall the plugin if this Claude Code (maybe
    /// upgraded since) has mods. No-op when never installed; an older app's
    /// partial settings install is topped up.
    static func refresh() async {
        // pluginPresent: a plugin-only install (pre-release build of this feature) gets its hooks back.
        guard isInstalled() || settingsHooksPartiallyInstalled() || pluginPresent() else { return }
        do {
            try await install()
        } catch {
            HookLog.write("Claude Code integration refresh failed: \(error.localizedDescription)")
        }
    }

    private static func installNow() async throws -> Mode {
        let pluginChanged = try copyFiles()
        installPiExtension()
        try installSettingsHooks()
        switch await claudeSupportsMods() {
        case true?:
            if pluginPresent() && !pluginEnabled() {
                HookLog.write("Claude Code plugin is disabled; leaving it so")
            } else if pluginPresent() && pluginChanged {
                // Claude Code runs the copy made at install time: replace it.
                _ = await claude(["plugin", "uninstall", pluginID])
                await installPlugin()
            } else if !pluginPresent() {
                await installPlugin()
            }
        case false?:
            HookLog.write("Claude Code has no mods: settings.json hooks only")
        case nil:
            HookLog.write("couldn't run claude to check for mods; plugin left as it was")
        }
        let mode = installedMode() ?? .settings
        HookLog.write("Claude Code integration: \(mode == .plugin ? "settings hooks + plugin" : "settings hooks")")
        return mode
    }

    // MARK: - Plugin

    /// The same events for Pi agents, from its extension API (no hooks there).
    private static func installPiExtension() {
        let fm = FileManager.default
        let agentDir = piExtensionURL.deletingLastPathComponent().deletingLastPathComponent()
        guard fm.fileExists(atPath: agentDir.path), let bundled = bundledPiExtension,
              let data = try? Data(contentsOf: bundled), (try? Data(contentsOf: piExtensionURL)) != data,
              isOurPiExtension() else { return }
        do {
            try fm.createDirectory(at: piExtensionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: piExtensionURL, options: .atomic)
            HookLog.write("Pi extension installed")
        } catch {
            HookLog.write("Pi extension install failed: \(error.localizedDescription)")
        }
    }

    /// Absent, or a copy we wrote (marker line): a user's own same-named file is left alone.
    private static func isOurPiExtension() -> Bool {
        guard let text = try? String(contentsOf: piExtensionURL, encoding: .utf8) else {
            return !FileManager.default.fileExists(atPath: piExtensionURL.path)
        }
        return text.contains(piMarker)
    }

    static let piMarker = "Agent Organizer extension for Pi"

    /// Copies the script and the plugin folder; true when the plugin changed.
    private static func copyFiles() throws -> Bool {
        guard let bundledScript = Bundle.main.url(forResource: "ao-hook", withExtension: "sh"),
              let bundledPlugin = bundledPluginDirectory else {
            throw InstallError.bundledScriptMissing
        }
        let fm = FileManager.default
        try fm.createDirectory(at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: scriptURL.path) { try fm.removeItem(at: scriptURL) }
        try fm.copyItem(at: bundledScript, to: scriptURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        // Bundled files only: a stray .DS_Store in the copy mustn't force a reinstall.
        let copy = fileContents(pluginDirectory)
        guard !fileContents(bundledPlugin).allSatisfy({ copy[$0.key] == $0.value }) else { return false }
        if fm.fileExists(atPath: pluginDirectory.path) { try fm.removeItem(at: pluginDirectory) }
        try fm.copyItem(at: bundledPlugin, to: pluginDirectory)
        return true
    }

    /// Relative path → bytes of every file under `dir` (hidden ones included).
    static func fileContents(_ dir: URL) -> [String: Data] {
        var files: [String: Data] = [:]
        let base = dir.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return files }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            files[String(path.dropFirst(base.count + 1))] = try? Data(contentsOf: url)
        }
        return files
    }

    /// The probe for "this Claude Code has mods": validate reads the module the
    /// way the engine will and lists the events it hooks. Older versions have
    /// no `plugin validate`, or don't read `modules`. nil: claude didn't run.
    private static func claudeSupportsMods() async -> Bool? {
        let plugin = pluginDirectory.appendingPathComponent("agent-organizer").path
        let (status, output) = await claude(["plugin", "validate", "--json", plugin])
        if output.contains("turn.complete") { return true }
        // 127: not found via the login shell; <0: couldn't start or timed out.
        return status == 127 || status < 0 || output.isEmpty ? nil : false
    }

    private static func installPlugin() async {
        // Fails harmlessly when already added (e.g. an earlier install).
        _ = await claude(["plugin", "marketplace", "add", pluginDirectory.path])
        let (status, output) = await claude(["plugin", "install", pluginID])
        if status != 0 { HookLog.write("claude plugin install: \(output.prefix(300))") }
    }

    /// An `installed_plugins.json` entry, enabled or not.
    private static func pluginPresent() -> Bool {
        guard let data = try? Data(contentsOf: installedPluginsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any],
              let entries = plugins[pluginID] as? [Any] else { return false }
        return !entries.isEmpty
    }

    /// Present and not switched off in `/plugin` (`enabledPlugins[id] == false`).
    private static func pluginEnabled() -> Bool {
        guard pluginPresent() else { return false }
        let enabled = (try? readSettings())?["enabledPlugins"] as? [String: Any]
        return enabled?[pluginID] as? Bool != false
    }

    private static let gate = Gate()

    /// Runs operations one after another.
    private actor Gate {
        private var tail: Task<Void, Never>?

        func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
            let previous = tail
            let task = Task { () async throws -> T in
                await previous?.value
                return try await operation()
            }
            tail = Task { _ = try? await task.value }
            return try await task.value
        }
    }

    /// Runs `claude <args>` through the login shell (GUI apps lack the user's
    /// PATH). Waits for the process, not the pipe (a lingering grandchild can
    /// hold that open); after 60 s it's terminated, then killed.
    private static func claude(_ args: [String]) async -> (Int32, String) {
        final class Output: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            private var resumed = false
            func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
            /// The text once; nil on later calls, so the continuation resumes once.
            func finish() -> String? {
                lock.withLock {
                    guard !resumed else { return nil }
                    resumed = true
                    return String(decoding: data, as: UTF8.self)
                }
            }
        }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: TmuxPaths.loginShell())
            process.arguments = ["-lc", "exec claude " + args.map(RemoteSession.quote).joined(separator: " ")]
            let pipe = Pipe()
            let output = Output()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil } else { output.append(chunk) }
            }
            process.terminationHandler = { p in
                // Give the reader a moment for the last chunk, then stop it.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if let text = output.finish() { continuation.resume(returning: (p.terminationStatus, text)) }
                }
            }
            do {
                try process.run()
            } catch {
                if let text = output.finish() { continuation.resume(returning: (-1, text)) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                guard process.isRunning else { return }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    // MARK: - settings.json hooks

    private static func settingsHooksInstalled() -> Bool {
        guard let hooks = try? readHooks() else { return false }
        return events.allSatisfy { (hooks[$0] as? [[String: Any]])?.contains(where: groupIsOurs) ?? false }
    }

    private static func settingsHooksPartiallyInstalled() -> Bool {
        guard let hooks = try? readHooks() else { return false }
        return events.contains { (hooks[$0] as? [[String: Any]])?.contains(where: groupIsOurs) ?? false }
    }

    private static func installSettingsHooks() throws {
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

    private static func removeSettingsHooks() throws {
        guard settingsHooksPartiallyInstalled() else { return }
        var root = try readSettings()
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for event in events {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups.removeAll(where: groupIsOurs)
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        root["hooks"] = hooks
        try writeSettings(root)
    }

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
