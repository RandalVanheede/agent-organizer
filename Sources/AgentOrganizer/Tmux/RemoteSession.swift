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
    @MainActor static func launchCommand(host: String, session: String, cwd: String, command: String?) -> String {
        func create(withTokens: Bool) -> String {
            var create = "\(tmux) new-session -d -s \(session) -c \(quote(cwd)) \(paneEnv(host: host, session: session, envTokens: withTokens))"
            if let command, !command.isEmpty {
                create += " && \(typeWhenReady(session: session, command: command))"
            }
            return create
        }
        // Re-running `create` on reconnect is harmless: new-session fails
        // for an existing session, so send-keys is skipped. The reconnect copy
        // never carries tokens: it runs again on every reconnect for the
        // session's whole life, and the pane already has its env.
        return wrap(host: host, session: session, firstConnect: create(withTokens: true), reconnect: create(withTokens: false))
    }

    /// Restart: kill whatever runs in the remote pane, start `command` fresh.
    @MainActor static func restartCommand(host: String, session: String, cwd: String, command: String?) -> String {
        var respawn = "\(tmux) respawn-pane -k -c \(quote(cwd)) -t \(session) \(paneEnv(host: host, session: session))"
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
    tok=$(sed -n 's/^open=//p' "$HOME/.cache/agent-organizer/tokens/${AO_SESSION:-none}" 2>/dev/null); [ -n "$tok" ] || tok="$AO_OPEN_TOKEN"
    [ -n "$tok" ] || exit 1
    t=$(tmux -L agent-organizer display -p -t "${AO_SESSION:-$TMUX_PANE}" '#{pane_tty}' 2>/dev/null)
    [ -n "$t" ] || exit 1
    p=$(printf '%s' "$1" | base64 | tr -d '\n')
    printf '\033Ptmux;\033\033Ptmux;\033\033\033\033]7731;%s;%s\007\033\033\\\033\\' "$tok" "$p" > "$t"
    """#

    /// (Re)written on every connect so it stays current; base64 dodges quoting.
    private static var installOpener: String {
        let b64 = Data((openerScript + "\n").utf8).base64EncodedString()
        return "sh -c \(quote("d=\"\(openerDir)\"; mkdir -p \"$d\" && echo \(b64) | base64 -d > \"$d/xdg-open\" && chmod 755 \"$d/xdg-open\""))"
    }

    /// Env for the remote pane (tmux ≥ 3.2 `-e`). Tokens only when this run
    /// couldn't deliver them as a file (no key auth): argv is readable by
    /// other users of a shared host (`/proc/<pid>/cmdline`).
    @MainActor private static func paneEnv(host: String, session: String, envTokens: Bool = true) -> String {
        var env = "-e BROWSER=\"\(openerDir)/xdg-open\" -e AO_SESSION=\(session) -e PATH=\"\(openerDir):$PATH\""
        if envTokens && !tokenHosts.contains(host) {
            HookLog.write("tokens for \(session) on \(host) passed in the environment (token file not delivered)")
            env += " -e AO_OPEN_TOKEN=\(token(.open, session)) -e AO_HOOK_TOKEN=\(token(.hook, session))"
        }
        return env
    }

    // MARK: Per-session tokens

    /// One token per purpose, so a leaked event token can't open URLs.
    enum TokenPurpose: String { case open, hook }

    /// Per-session secret so text merely *printed* in the pane (a cat'ed file,
    /// web content) can't forge a request: HMAC(app key, purpose:session),
    /// derivable again after an app restart while the session lives on.
    static func token(_ purpose: TokenPurpose, _ session: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(purpose.rawValue):\(session)".utf8), using: openerKey)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time check of an OSC payload's token field.
    private static func tokenMatches(_ given: Data, _ purpose: TokenPurpose, _ session: String) -> Bool {
        let expected = Data(token(purpose, session).utf8)
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Session names go into remote shell commands and file paths: ours are
    /// `ao_<slug>_<hex>`, an adopted orphan's could be anything.
    static func isSafeSession(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// Hosts that took token files this run; their panes get no tokens in argv.
    @MainActor private static var tokenHosts: Set<String> = []

    /// Writes each session's tokens to a private file on the remote
    /// (`~/.cache/agent-organizer/tokens/<session>`, 0600) over ssh stdin, and
    /// refreshes the opener and hook scripts, so panes already running switch
    /// to the file too. Needs key auth (BatchMode); without it launches fall
    /// back to tokens in the environment.
    @MainActor static func deliverTokens(host: String, sessions: [String]) {
        let safe = sessions.filter(isSafeSession)
        guard !host.hasPrefix("-") else { return }
        var script = "umask 077; d=\"$HOME/.cache/agent-organizer\"; mkdir -p \"$d/tokens\" \"$d/bin\" && [ ! -L \"$d\" ] && [ ! -L \"$d/tokens\" ] && [ -O \"$d\" ] && [ -O \"$d/tokens\" ] && chmod 700 \"$d\" \"$d/tokens\" || exit 1\n"
        for session in safe {
            script += "printf 'open=%s\\nhook=%s\\n' \(token(.open, session)) \(token(.hook, session)) > \"$d/tokens/\(session)\"\n"
        }
        for (name, body) in [("xdg-open", openerScript), ("ao-hook", hookScript)] {
            script += "echo \(Data((body + "\n").utf8).base64EncodedString()) | base64 -d > \"$d/bin/\(name)\" && chmod 755 \"$d/bin/\(name)\"\n"
        }
        script += "echo \(safe.count) token files\n"
        runRemote(host: host, script: script, label: "Session tokens") { ok in
            if ok { tokenHosts.insert(host) }
        }
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
        guard parts.count == 2, tokenMatches(Data(parts[0]), .open, session) else {
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

    // MARK: Claude Code events from the remote

    /// Private OSC the remote `ao-hook` emits: "<hook token>;<base64 event JSON>".
    static let hookOSC = 7732
    /// Set by AppState: routes a remote event like a local event file.
    @MainActor static var onHookEvent: ((HookEventWatcher.Event) -> Void)?

    /// Remote stand-in for the app's `ao-hook`, run by the Claude Code plugin
    /// (never settings hooks: the remote's settings.json is left alone). Same
    /// tty route and double passthrough wrap as the opener.
    private static let hookScript = #"""
    #!/bin/sh
    # Installed by Agent Organizer: sends Claude Code events to the app on the Mac.
    tok=$(sed -n 's/^hook=//p' "$HOME/.cache/agent-organizer/tokens/${AO_SESSION:-none}" 2>/dev/null); [ -n "$tok" ] || tok="$AO_HOOK_TOKEN"
    [ -n "$tok" ] || { cat >/dev/null 2>&1; exit 0; }
    t=$(tmux -L agent-organizer display -p -t "${AO_SESSION:-$TMUX_PANE}" '#{pane_tty}' 2>/dev/null)
    [ -n "$t" ] || { cat >/dev/null 2>&1; exit 0; }
    case "$1" in *[!A-Za-z]*|'') cat >/dev/null 2>&1; exit 0 ;; esac
    p=$( { printf '{"event":"%s","payload":' "$1"; cat; printf '}'; } | base64 | tr -d '\n')
    printf '\033Ptmux;\033\033Ptmux;\033\033\033\033]7732;%s;%s\007\033\033\\\033\\' "$tok" "$p" > "$t"
    """#

    static func handleHookEvent(_ payload: ArraySlice<UInt8>, host: String, session: String) {
        let parts = Data(payload).split(separator: UInt8(ascii: ";"), maxSplits: 1)
        guard parts.count == 2, tokenMatches(Data(parts[0]), .hook, session) else {
            HookLog.write("remote hook event from \(host) rejected: bad token")
            return
        }
        guard let data = Data(base64Encoded: Data(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var event = HookEventWatcher.Event(obj) else { return }
        event.session = session
        MainActor.assumeIsolated { onHookEvent?(event) }
    }

    /// Hosts set up this app run; the ssh round trip is done once per launch.
    @MainActor private static var integratedHosts: Set<String> = []

    /// Copies the Claude Code plugin and the remote `ao-hook` to the remote's
    /// `~/.cache/agent-organizer/` and, when its Claude Code has mods, installs
    /// the plugin from there (once; later runs only refresh the files, which a
    /// folder marketplace reads in place). Older Claude Code: files only, and
    /// remote status stays pane-title based. Script goes over stdin, so its size
    /// is no concern. Needs key auth (BatchMode); failures are only logged.
    @MainActor static func installClaudeIntegration(host: String) {
        guard !host.hasPrefix("-"), !integratedHosts.contains(host),
              let bundled = HookInstaller.bundledPluginDirectory else { return }
        integratedHosts.insert(host)
        // Owned and private: this code runs in every Claude session of that user.
        let files = HookInstaller.fileContents(bundled)
        // Claude Code runs a cached copy: reinstall when the plugin changed.
        let version = SHA256.hash(data: files.sorted { $0.key < $1.key }.reduce(into: Data()) { $0.append(Data($1.key.utf8)); $0.append($1.value) })
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        var script = "umask 077; d=\"$HOME/.cache/agent-organizer\"; p=\"$d/claude-plugin\"; mkdir -p \"$d/bin\" && [ -O \"$d\" ] && chmod 700 \"$d\" || exit 1\n"
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            // Paths come from our own bundle; quoted anyway.
            script += "mkdir -p \"$p/\"\(quote((path as NSString).deletingLastPathComponent)) && echo \(data.base64EncodedString()) | base64 -d > \"$p/\"\(quote(path))\n"
        }
        script += "v=\(version)\n"
        script += "echo \(Data((hookScript + "\n").utf8).base64EncodedString()) | base64 -d > \"$d/bin/ao-hook\" && chmod 755 \"$d/bin/ao-hook\"\n"
        // Pi agents: its extension, only where Pi is set up; before the claude checks, which may exit.
        if let pi = HookInstaller.bundledPiExtension.flatMap({ try? Data(contentsOf: $0) }) {
            // Atomic (tmp + mv): Pi loads it in every session. Never replaces a user's own same-named file.
            script += "x=\"$HOME/.pi/agent/extensions/agent-organizer.ts\"; if [ -d \"$HOME/.pi/agent\" ] && { [ ! -e \"$x\" ] || grep -q '\(HookInstaller.piMarker)' \"$x\"; }; then mkdir -p \"$HOME/.pi/agent/extensions\" && echo \(pi.base64EncodedString()) | base64 -d > \"$x.tmp\" && mv -f \"$x.tmp\" \"$x\" && echo 'pi extension;'; fi\n"
        }
        script += #"""
        \#(findClaude)
        [ -x "$c" ] || { echo "no claude"; exit 0; }
        [ "$(cat "$d/plugin-installed" 2>/dev/null)" = "$v" ] && { echo "up to date"; exit 0; }
        "$c" plugin validate --json "$p/agent-organizer" </dev/null 2>/dev/null | grep -q turn.complete || { echo "claude too old for mods"; exit 0; }
        "$c" plugin marketplace add "$p" </dev/null >/dev/null 2>&1
        # Replace only our own earlier install (never re-enable one the user removed some other way).
        [ -f "$d/plugin-installed" ] && "$c" plugin uninstall agent-organizer@agent-organizer </dev/null >/dev/null 2>&1
        # exit 0 on failure: only ssh trouble should make the app retry.
        if "$c" plugin install agent-organizer@agent-organizer </dev/null >/dev/null 2>&1; then echo "$v" > "$d/plugin-installed"; echo "installed $v"; else rm -f "$d/plugin-installed"; echo "plugin install failed"; fi
        """#
        // ssh failed (host down, no key auth): let the next attempt retry.
        runRemote(host: host, script: script, label: "Claude Code integration") { ok in
            if !ok { integratedHosts.remove(host) }
        }
    }

    /// Sets `c` to the remote's claude. `sh -s` over ssh isn't a login shell, so
    /// nvm / npm-global installs need the login shell's PATH.
    private static let findClaude = #"c=$(command -v claude 2>/dev/null) || c=$("${SHELL:-sh}" -lc 'command -v claude' </dev/null 2>/dev/null) || c="$HOME/.local/bin/claude""#

    /// Undoes `installClaudeIntegration` (Preferences › Uninstall).
    @MainActor static func uninstallClaudeIntegration(host: String) {
        guard !host.hasPrefix("-") else { return }
        integratedHosts.remove(host)
        let script = """
        d="$HOME/.cache/agent-organizer"
        \(findClaude)
        if [ -x "$c" ]; then "$c" plugin uninstall agent-organizer@agent-organizer </dev/null >/dev/null 2>&1; "$c" plugin marketplace remove agent-organizer </dev/null >/dev/null 2>&1; fi
        x="$HOME/.pi/agent/extensions/agent-organizer.ts"; grep -q '\(HookInstaller.piMarker)' "$x" 2>/dev/null && rm -f "$x"
        rm -rf "$d/claude-plugin" "$d/bin/ao-hook" "$d/plugin-installed"; echo removed
        """
        runRemote(host: host, script: script, label: "Claude Code integration removal")
    }

    /// `done(succeeded)` runs on the main actor.
    private static func runRemote(host: String, script: String, label: String, done: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "sh -s"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { p in
            let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            HookLog.write("\(label) on \(host): status \(p.terminationStatus) \(said)")
            let ok = p.terminationStatus == 0
            if let done { DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } } }
        }
        do {
            try process.run()
        } catch {
            HookLog.write("\(label) on \(host): ssh didn't start")
            if let done { DispatchQueue.main.async { MainActor.assumeIsolated { done(false) } } }
            return
        }
        // ssh gone early: EPIPE instead of SIGPIPE (which would kill the app), and a throwing write.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .utility).async {
            try? input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
            try? input.fileHandleForWriting.close()
        }
        // A hung remote claude must not keep ssh around forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) { if process.isRunning { process.terminate() } }
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
        guard !host.hasPrefix("-"), isSafeSession(session) else {
            HookLog.write("remote kill skipped: unsafe host or session name")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "\(tmux) kill-session -t \(session); rm -f \"$HOME/.cache/agent-organizer/tokens/\"\(quote(session))"]
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
        // set-titles forwards the remote pane title (Claude's "✳ topic") to our pane.
        let options = ["status off", "mouse on", "set-clipboard on", "allow-passthrough on", "escape-time 0", "focus-events on",
                       "set-titles on", "set-titles-string \"#T\""]
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
