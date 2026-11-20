import CryptoKit
import Foundation

/// Browser for remote agents (opt-in, `Store.remoteBrowser`). Playwright MCP
/// runs on the Mac, so Chrome is visible and nothing is installed remotely;
/// one `ssh -N` per host reverse-forwards its port (`-R`) so remote Claude
/// reaches it at `http://127.0.0.1:<port>/mcp`, and offers a SOCKS proxy
/// (`-D`) the browser sends all traffic through, so the remote's localhost
/// and ddev/internal hostnames load as they would there.
/// Any user on the remote host can reach the forwarded port, so it lands on
/// a `TokenGate` (Bearer token, fresh per tunnel start; also blocks
/// `browser_run_code_unsafe`) in front of Playwright, which only answers
/// requests carrying the gate's per-run secret (`gateCheckJS`, so programs on
/// this Mac can't go around the gate) and uses a dedicated profile under App
/// Support, never the user's own Chrome.
@MainActor
enum RemoteBrowser {
    private static var hosts: Set<String> = []
    private static var running: [(host: String, process: Process)] = []
    private static var gates: [String: TokenGate] = [:]
    private static var tunnels: Set<String> = []

    /// Forwarded port, same number on both ends. Stable per host, so the
    /// remote's `claude mcp` entry stays valid. Playwright itself listens on
    /// port + 2000, SOCKS on port + 1000.
    static func port(for host: String) -> Int {
        let b = Array(SHA256.hash(data: Data(host.utf8)))
        return 47000 + (Int(b[0]) << 8 | Int(b[1])) % 1000
    }

    static func ensure(host: String) {
        // A leading "-" would make ssh read the host as an option.
        guard !host.hasPrefix("-"), hosts.insert(host).inserted else { return }
        let port = port(for: host), socks = port + 1000, mcpPort = port + 2000
        // Per run, never in an argv: only the gate and Playwright's environment know it.
        let secret = randomHex()
        let browserDir = Store.appSupportDirectory().appendingPathComponent("browser", isDirectory: true)
        let dir = browserDir.appendingPathComponent("\(port)", isDirectory: true)
        // Playwright's workspace (its file tools' root) is its working directory: keep that an
        // empty `work/`, with the profile, output and logs beside it, out of npx's config path.
        let work = dir.appendingPathComponent("work", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // Outside `dir`: Playwright's file tools can read their workspace (`dir`).
        let preload = browserDir.appendingPathComponent("gate-check.js")
        try? gateCheckJS.write(to: preload, atomically: true, encoding: .utf8)
        // Remote paths mean nothing here, hence --ignore-roots; screenshots still
        // reach Claude inline in the MCP response. IPv4 only: plain `localhost`
        // binds ::1. The gate sends Host 127.0.0.1:<mcpPort>, which Playwright allows by default.
        let mcp = "export NODE_OPTIONS=\(RemoteSession.quote("--require \"\(preload.path)\"")); "
            + "exec npx -y @playwright/mcp@0.0.85 --host 127.0.0.1 --port \(mcpPort)"
            // Saved files land on the Mac; absolute paths keep the remote agent from
            // mistaking "./shot.png" for a file in its own workspace.
            + " --shared-browser-context --ignore-roots --file-paths absolute"
            + " --user-data-dir ../profile --output-dir ../output --proxy-server socks5://127.0.0.1:\(socks) 2>>../mcp.log" // why it exits: browser/<port>/mcp.log
        // A previous run killed without quitting (pkill, crash) leaves its bridge
        // behind holding these ports, with possibly stale flags: replace it.
        killStale("playwright-mcp --host 127.0.0.1 --port \(mcpPort) ")
        killStale("ServerAliveInterval=30 -R 127.0.0.1:\(port):127.0.0.1:\(port) -D 127.0.0.1:\(socks) \(NSRegularExpression.escapedPattern(for: host))") // pkill reads a leading "-" as an option
        supervise("browser mcp \(host)", host: host, port: mcpPort) {
            let p = Process()
            // The account's shell, not $SHELL: the app inherits $SHELL from whatever
            // launched it, and a bash login PATH found a stale npm 6 npx (no `-y`).
            p.executableURL = URL(fileURLWithPath: getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_shell) } ?? "/bin/zsh")
            p.arguments = ["-lc", mcp] // login shell: GUI apps lack nvm/Homebrew on PATH
            p.currentDirectoryURL = work
            p.environment = ProcessInfo.processInfo.environment.merging(["AO_GATE_SECRET": secret]) { $1 }
            return p
        }
        // The tunnel only starts once the gate holds its port: otherwise it would
        // forward (and Claude would send its token) to whatever else listens there.
        let gate = TokenGate(port: port, upstream: mcpPort, secret: secret, onReady: {
            DispatchQueue.main.async { MainActor.assumeIsolated { startTunnel(host: host, port: port, socks: socks) } }
        }, onFailure: { error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    HookLog.write("browser gate \(host) on port \(port) failed: \(error); browser bridge stopped")
                    stop(host: host)
                }
            }
        })
        guard let gate else {
            HookLog.write("browser gate \(host): invalid port \(port)")
            stop(host: host)
            return
        }
        gates[host] = gate
    }

    /// Each (re)start gets a fresh token, registered on the remote only once the
    /// tunnel has held its port for a few seconds (a squatter on the remote port
    /// makes ssh exit first, so it never sees the token).
    private static func startTunnel(host: String, port: Int, socks: Int) {
        guard hosts.contains(host), tunnels.insert(host).inserted else { return }
        let log = Store.appSupportDirectory().appendingPathComponent("browser/\(port)/tunnel.log") // why ssh exits
        supervise("browser tunnel \(host)", host: host, port: socks, stderrLog: log) {
            MainActor.assumeIsolated {
                let token = randomHex()
                gates[host]?.setToken(token)
                let p = ssh(["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30",
                             "-R", "127.0.0.1:\(port):127.0.0.1:\(port)", "-D", "127.0.0.1:\(socks)", host])
                nonisolated(unsafe) let tunnel = p
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    MainActor.assumeIsolated {
                        if tunnel.isRunning, hosts.contains(host) { register(host: host, port: port, token: token) }
                    }
                }
                return p
            }
        }
    }

    /// Hosts with a running bridge.
    static var activeHosts: Set<String> { hosts }

    /// `deregister`: also remove `ao-browser` and its token file on the remote, so
    /// Claude there stops calling a port another remote user could then take over.
    static func stop(host: String, deregister: Bool = false) {
        if deregister, hosts.contains(host) { self.deregister(host: host) }
        hosts.remove(host)
        tunnels.remove(host)
        gates.removeValue(forKey: host)?.cancel()
        for entry in running where entry.host == host { entry.process.terminate() }
        running.removeAll { $0.host == host }
    }

    private static func randomHex() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    /// Preloaded into Playwright MCP's node (`NODE_OPTIONS=--require`): serves only
    /// requests carrying the gate's per-run secret, so a local program (another
    /// macOS user, a Docker container via host.docker.internal) can't reach
    /// Playwright's port directly. Fails closed when the secret is missing.
    static let gateCheckJS = """
    // Written by Agent Organizer (RemoteBrowser.gateCheckJS); regenerated on every start.
    const http = require('http'), crypto = require('crypto');
    const want = Buffer.from(process.env.AO_GATE_SECRET || '');
    const ok = (req) => {
      const got = Buffer.from(String(req.headers['x-ao-gate'] || ''));
      return want.length >= 32 && got.length === want.length && crypto.timingSafeEqual(got, want);
    };
    const createServer = http.createServer;
    http.createServer = function (...args) {
      const server = createServer.apply(this, args);
      const emit = server.emit;
      server.emit = function (event, req, resOrSocket) {
        if (event === 'request' && !ok(req)) { resOrSocket.statusCode = 403; resOrSocket.end(); return true; }
        if ((event === 'upgrade' || event === 'connect') && !ok(req)) { resOrSocket.destroy(); return true; }
        return emit.apply(this, arguments);
      };
      return server;
    };

    """

    /// Quitting keeps the remote registration (agents reconnect after relaunch);
    /// turning the feature off removes it (`deregister`).
    static func stopAll(deregister: Bool = false) {
        if deregister { hosts.forEach { self.deregister(host: $0) } }
        hosts.removeAll()
        tunnels.removeAll()
        gates.values.forEach { $0.cancel() }
        gates.removeAll()
        running.forEach { $0.process.terminate() }
        running.removeAll()
    }

    /// Keeps `make()` running while `host` is wanted. A port still in use after
    /// `killStale` belongs to something else: logged and rechecked every 30 s.
    private static func supervise(_ name: String, host: String, port: Int, stderrLog: URL? = nil,
                                  make: @escaping @Sendable () -> Process) {
        guard hosts.contains(host) else { return }
        let retry = { @Sendable (delay: Double) in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { supervise(name, host: host, port: port, stderrLog: stderrLog, make: make) }
            }
        }
        if isListening(port) {
            HookLog.write("\(name): port \(port) is taken by another program, retrying in 30 s")
            retry(30)
            return
        }
        let process = make()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if let stderrLog {
            if !FileManager.default.fileExists(atPath: stderrLog.path) {
                FileManager.default.createFile(atPath: stderrLog.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: stderrLog) {
                handle.seekToEndOfFile()
                process.standardError = handle
            }
        }
        process.terminationHandler = { p in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    running.removeAll { $0.process === p }
                    guard hosts.contains(host) else { return }
                    HookLog.write("\(name) exited (status \(p.terminationStatus)), retrying in 10 s")
                    retry(10)
                }
            }
        }
        do {
            try process.run()
            running.append((host, process))
            HookLog.write("\(name) started on port \(port)")
        } catch {
            HookLog.write("\(name) failed to start: \(error)")
        }
    }

    /// Writes the current token where Claude's `headersHelper` reads it, and adds
    /// the MCP server to the remote user's Claude config if it isn't there yet
    /// (agents already running pick that up after a restart; a new token only
    /// needs the file). The token never appears in any argv (other
    /// remote users can list processes): it arrives over stdin, `printf` (a
    /// builtin) writes it to a 0600 file, and Claude reads it via `headersHelper`.
    /// Interactive login shell: that's where nvm & co. put `claude` on PATH.
    private static func register(host: String, port: Int, token: String) {
        let script = """
        umask 077; d="$HOME/.cache/agent-organizer"; mkdir -p "$d" || exit 1
        IFS= read -r t || exit 1
        printf '{"Authorization":"Bearer %s"}\\n' "$t" > "$d/browser-auth.json" || exit 1
        claude mcp get ao-browser 2>/dev/null | grep -qF 'http://127.0.0.1:\(port)/mcp?v=2' && exit 0
        claude mcp remove -s user ao-browser >/dev/null 2>&1
        exec claude mcp add-json -s user ao-browser '{"type":"http","url":"http://127.0.0.1:\(port)/mcp?v=2","headersHelper":"cat ~/.cache/agent-organizer/browser-auth.json"}'
        """
        let shell = "sh -c \(RemoteSession.quote(script))"
        let process = ssh([host, "$SHELL -ilc \(RemoteSession.quote(shell))"])
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { p in
            HookLog.write("browser mcp registration on \(host): status \(p.terminationStatus)")
        }
        // ssh gone early: EPIPE and a throwing write, not SIGPIPE / an ObjC exception.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        enqueueRemote(host, process, onlyIfActive: true) { _ in
            try? input.fileHandleForWriting.write(contentsOf: Data((token + "\n").utf8))
            try? input.fileHandleForWriting.close()
        }
    }

    /// Fire-and-forget; a host that's unreachable now keeps its entry (logged).
    private static func deregister(host: String) {
        let script = #"claude mcp remove -s user ao-browser >/dev/null 2>&1; rm -f "$HOME/.cache/agent-organizer/browser-auth.json""#
        let process = ssh([host, "$SHELL -ilc \(RemoteSession.quote("sh -c \(RemoteSession.quote(script))"))"])
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { p in
            HookLog.write("browser mcp deregistration on \(host): status \(p.terminationStatus)")
        }
        enqueueRemote(host, process, onlyIfActive: false)
    }

    /// Register / deregister for one host run one at a time, in order: each is a
    /// slow login shell, and unordered a late deregister could wipe a fresh
    /// registration, or a late register leave one behind after turning off.
    private static var remoteOps: [String: [(process: Process, onlyIfActive: Bool, onLaunch: (Process) -> Void)]] = [:]

    private static func enqueueRemote(_ host: String, _ process: Process, onlyIfActive: Bool,
                                      onLaunch: @escaping (Process) -> Void = { _ in }) {
        remoteOps[host, default: []].append((process, onlyIfActive, onLaunch))
        if remoteOps[host]?.count == 1 { launchNextRemote(host) }
    }

    private static func launchNextRemote(_ host: String) {
        guard let op = remoteOps[host]?.first else { return }
        // A registration queued before the feature was turned off is dropped.
        guard !op.onlyIfActive || hosts.contains(host) else { return remoteOpFinished(host) }
        let log = op.process.terminationHandler
        op.process.terminationHandler = { p in
            log?(p)
            DispatchQueue.main.async { MainActor.assumeIsolated { remoteOpFinished(host) } }
        }
        do {
            try op.process.run()
            op.onLaunch(op.process)
        } catch {
            remoteOpFinished(host)
        }
    }

    private static func remoteOpFinished(_ host: String) {
        remoteOps[host]?.removeFirst()
        if remoteOps[host]?.isEmpty == true { remoteOps[host] = nil }
        launchNextRemote(host)
    }

    nonisolated private static func ssh(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"] + args
        return p
    }

    /// Blocks briefly (pkill waits for nothing); the ports free up as the processes exit.
    nonisolated private static func killStale(_ pattern: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", pattern]
        do { try p.run(); p.waitUntilExit() } catch { return }
        if p.terminationStatus == 0 {
            HookLog.write("browser: killed stale process matching \(pattern)")
            Thread.sleep(forTimeInterval: 0.5) // let it release the port before supervise checks it
        }
    }

    nonisolated private static func isListening(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
