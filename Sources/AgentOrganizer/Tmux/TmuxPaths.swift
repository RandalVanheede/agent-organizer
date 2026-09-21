import Foundation

/// Locates the `tmux` binary and this app's dedicated socket/config, without
/// ever touching the user's own tmux server or config.
struct TmuxPaths {
    /// The statically-linked tmux shipped in the app bundle (see
    /// scripts/build-tmux.sh). Preferred so users need no Homebrew.
    static var bundledTmux: String? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("bin/tmux"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.path
    }

    static func resolveTmuxBinary() -> String? {
        if let bundled = bundledTmux { return bundled }
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return resolveViaLoginShell()
    }

    /// GUI apps on macOS inherit a minimal PATH (no Homebrew, no nvm, etc.).
    /// Re-resolve through the user's actual login shell as a fallback.
    private static func resolveViaLoginShell() -> String? {
        let shell = loginShell()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v tmux"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty
        else { return nil }
        return output
    }

    static func socketPath() -> String {
        Store.appSupportDirectory().appendingPathComponent("tmux.sock").path
    }

    static func loginShell() -> String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}
