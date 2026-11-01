import AppKit
import CryptoKit

/// Agents in a remote folder (HBY-13). The agent is still a *local* tmux
/// session (so status, persistence and the terminal cache work unchanged),
/// but what runs in it is `ssh -t <host>` attached to a same-named tmux
/// session on the remote's own `-L agent-organizer` server. That remote
/// session is where the tool really lives, so it survives the laptop
/// sleeping or the network dropping; the local side reconnects on its own.
enum RemoteSession {
    /// Remote tmux server name (`tmux -L`), kept apart from the user's own.
    private static let tmux = "tmux -L agent-organizer"

    /// The local pane's command (run by tmux via the user's shell). `sh -c`
    /// so the reconnect loop works whatever that shell is (fish etc.); a
    /// login shell takes over afterwards so the tab stays usable.
    static func launchCommand(host: String, session: String, cwd: String, command: String?) -> String {
        var create = "\(tmux) new-session -d -s \(session) -c \(quote(cwd)) \(openerEnv(session))"
        if let command, !command.isEmpty {
            create += " && \(typeWhenReady(session: session, command: command))"
        }
        // Re-running `create` on reconnect is harmless: new-session fails
        // for an existing session, so send-keys is skipped.
        return wrap(host: host, session: session, firstConnect: create, reconnect: create)
    }

    /// Restart: kill whatever runs in the remote pane, start `command` fresh.
    static func restartCommand(host: String, session: String, cwd: String, command: String?) -> String {
        var respawn = "\(tmux) respawn-pane -k -c \(quote(cwd)) -t \(session) \(openerEnv(session))"
        if let command, !command.isEmpty {
            respawn += " && \(typeWhenReady(session: session, command: command))"
        }
        return wrap(host: host, session: session, firstConnect: respawn, reconnect: nil)
    }

    /// Keys typed before the shell's line editor is up can lose their Enter
    /// (seen locally), so wait until the pane shows anything (the prompt;
    /// the pane starts / respawns blank), max ~5 s, plus a short grace.
    /// `sh -c`: the remote login shell running this may be fish.
    private static func typeWhenReady(session: String, command: String) -> String {
        let script = "i=0; while [ $i -lt 50 ] && [ -z \"$(\(tmux) capture-pane -p -t \(session) | tr -d '[:space:]')\" ]; do sleep 0.1; i=$((i+1)); done; sleep 0.3; \(tmux) send-keys -t \(session) -- \(quote(command)) Enter"
        return "sh -c \(quote(script))"
    }

    // MARK: Opening URLs on the Mac

    /// Private OSC the remote opener emits; the app's terminal view handles it.
    static let openerOSC = 7731
    private static let openerDir = "$HOME/.cache/agent-organizer/bin"

    /// Remote stand-in for a browser (`$BROWSER`, and `xdg-open` via PATH).
    /// Tools run it detached (no /dev/tty), so it writes to the agent pane's
    /// tty found via tmux. The OSC is wrapped for tmux passthrough twice:
    /// the remote tmux unwraps one layer, the app's local tmux the other.
    private static let openerScript = #"""
    #!/bin/sh
    # Installed by Agent Organizer: opens URLs on the Mac running the app.
    case "$1" in http://*|https://*) ;; *) exit 1 ;; esac
    [ -n "$AO_OPENER_TOKEN" ] || exit 1
    t=$(tmux -L agent-organizer display -p -t "${AO_SESSION:-$TMUX_PANE}" '#{pane_tty}' 2>/dev/null)
    [ -n "$t" ] || exit 1
    p=$(printf '%s' "$1" | base64 | tr -d '\n')
    printf '\033Ptmux;\033\033Ptmux;\033\033\033\033]7731;%s;%s\007\033\033\\\033\\' "$AO_OPENER_TOKEN" "$p" > "$t"
    """#

    /// (Re)written on every connect so it stays current; base64 dodges quoting.
    private static var installOpener: String {
        let b64 = Data((openerScript + "\n").utf8).base64EncodedString()
        return "sh -c \(quote("d=\"\(openerDir)\"; mkdir -p \"$d\" && echo \(b64) | base64 -d > \"$d/xdg-open\" && chmod 755 \"$d/xdg-open\""))"
    }

    /// Env for the remote pane (tmux ≥ 3.2 `-e`).
    private static func openerEnv(_ session: String) -> String {
        "-e BROWSER=\"\(openerDir)/xdg-open\" -e AO_SESSION=\(session) -e AO_OPENER_TOKEN=\(openerToken(session)) -e PATH=\"\(openerDir):$PATH\""
    }

    /// Per-session secret so text merely *printed* in the pane (a cat'ed file,
    /// web content) can't forge an open request: HMAC(app key, session name),
    /// derivable again after an app restart while the session lives on.
    static func openerToken(_ session: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(session.utf8), using: openerKey)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private static let openerKey: SymmetricKey = {
        let url = Store.appSupportDirectory().appendingPathComponent("opener.key")
        if let data = try? Data(contentsOf: url), data.count == 32 { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        return key
    }()

    /// Payload of `openerOSC`: "<token>;<base64 URL>". Only http(s) is opened.
    /// An OAuth URL whose redirect_uri is a localhost port (MCP login) gets
    /// that port forwarded to the remote first, where the callback listens.
    static func handleOpenRequest(_ payload: ArraySlice<UInt8>, host: String, session: String) {
        let parts = Data(payload).split(separator: UInt8(ascii: ";"), maxSplits: 1)
        guard parts.count == 2, String(decoding: parts[0], as: UTF8.self) == openerToken(session) else {
            HookLog.write("remote open from \(host) rejected: bad token")
            return
        }
        guard let data = Data(base64Encoded: Data(parts[1])), let text = String(data: data, encoding: .utf8),
              let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return }
        if let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "redirect_uri" })?.value.flatMap(URL.init(string:)),
           ["localhost", "127.0.0.1"].contains(redirect.host ?? ""), let port = redirect.port, port > 1024 {
            forward(port: port, host: host)
        }
        HookLog.write("remote open from \(host): \(url.absoluteString.prefix(120))")
        NSWorkspace.shared.open(url)
    }

    /// shortcut: fixed 10 min lifetime, enough for an OAuth login; upgrade if
    /// a flow ever needs the port longer.
    private static func forward(port: Int, host: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=5",
                             "-L", "\(port):localhost:\(port)", host]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return }
        HookLog.write("forwarding localhost:\(port) -> \(host) for OAuth callback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { if process.isRunning { process.terminate() } }
    }

    /// Fire-and-forget: killing the local session only drops the ssh link,
    /// the remote session must be killed explicitly. Needs key auth
    /// (BatchMode); otherwise the remote session lingers and is logged.
    static func kill(host: String, session: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "\(tmux) kill-session -t \(session)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { p in
            if p.terminationStatus != 0 {
                HookLog.write("remote kill \(session) on \(host) failed (status \(p.terminationStatus))")
            }
        }
        try? process.run()
    }

    /// First connect runs `firstConnect` (create / respawn), then attaches.
    /// ssh exits 255 only on connection errors: retry (`reconnect`, then
    /// attach). A normal exit (remote session ended, user detached) stops.
    private static func wrap(host: String, session: String, firstConnect: String, reconnect: String?) -> String {
        // Mirrors Resources/tmux.conf: clipboard + passthrough so Claude's own
        // (OSC 52) copy reaches the Mac; escape-time so Esc isn't delayed.
        let options = ["status off", "mouse on", "set-clipboard on", "allow-passthrough on", "escape-time 0", "focus-events on"]
            .map { "set -g \($0)" }.joined(separator: " ';' ")
        var attach = "\(installOpener); \(tmux) \(options); exec \(tmux) attach -t \(session)"
        let first = "\(firstConnect); \(attach)"
        if let reconnect { attach = "\(reconnect); \(attach)" }
        let script = """
        ssh -t \(quote(host)) \(quote(first)); \
        while [ $? -eq 255 ]; do echo 'Connection lost, reconnecting in 3s…'; sleep 3; \
        ssh -t \(quote(host)) \(quote(attach)); done
        """
        return "sh -c \(quote(script)); exec \"$SHELL\" -l"
    }

    /// One thing to upload on paste: a local file, or in-memory PNG data.
    enum Upload {
        case file(URL)
        case png(Data)
    }

    /// nil when the pasteboard holds nothing worth uploading (plain text paste).
    /// File URLs win over image data: a Finder copy also carries the icon as TIFF.
    static func pasteboardUploads(_ pb: NSPasteboard) -> [Upload]? {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        if !urls.isEmpty { return urls.map { .file($0) } }
        if let png = pb.data(forType: .png) { return [.png(png)] }
        if let tiff = pb.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return [.png(png)]
        }
        return nil
    }

    /// Streams each item over `ssh host 'cat > path'` (no scp/sftp needed) and
    /// calls back on the main thread with the remote paths that made it.
    static func upload(_ items: [Upload], to host: String, completion: @escaping @MainActor ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var paths: [String] = []
            for item in items {
                let tag = UUID().uuidString.prefix(8).lowercased()
                let name: String
                let input: FileHandle?
                let temp: URL?
                switch item {
                case .file(let url):
                    // Spaces etc. would need quoting in the prompt; keep it a bare word.
                    let safe = url.lastPathComponent.map { $0.isLetter || $0.isNumber || ".-_".contains($0) ? $0 : "_" }
                    name = "\(tag)-\(String(safe))"
                    input = try? FileHandle(forReadingFrom: url)
                    temp = nil
                case .png(let data):
                    name = "\(tag).png"
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                    try? data.write(to: url)
                    input = try? FileHandle(forReadingFrom: url)
                    temp = url
                }
                defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
                guard let input else { continue }
                // Private per-user dir (not shared /tmp); the remote echoes the
                // absolute path back since its $HOME isn't known here.
                let script = "umask 077; d=\"$HOME/.cache/agent-organizer-paste\"; mkdir -p \"$d\" && chmod 700 \"$d\" && cat > \"$d/\(name)\" && echo \"$d/\(name)\""
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host,
                                     "sh -c \(quote(script))"]
                process.standardInput = input
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit() // background queue, not the main run loop
                } catch {}
                try? input.close()
                let remote = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus == 0, remote.hasPrefix("/") {
                    paths.append(remote)
                } else {
                    HookLog.write("paste upload to \(host) failed (status \(process.terminationStatus))")
                }
            }
            DispatchQueue.main.async { completion(paths) }
        }
    }

    /// POSIX single-quote; the same escape also works in fish.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
