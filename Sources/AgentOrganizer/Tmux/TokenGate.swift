import Foundation
import Network

/// Front door for `RemoteBrowser`'s forwarded port. Any user on the remote
/// can reach that port and Playwright MCP has no auth of its own, so every
/// HTTP request (not just a connection's first) is parsed and checked here:
/// - it must carry `Authorization: Bearer <token>`;
/// - only `/mcp`, only GET/POST/DELETE, no chunked bodies: the body is read by
///   Content-Length and must be one JSON object;
/// - `tools/call` of a `deniedTools` entry is refused (`browser_run_code_unsafe`
///   runs Node code with full access to this Mac), and so is any call naming a
///   `filename`: those write caller-chosen files into Playwright's working
///   directory, e.g. an `.npmrc` that npx would obey on the next start;
/// - what goes upstream is rebuilt from what was checked: the JSON re-encoded
///   (no duplicate-key or escape tricks), Host rewritten, and `X-AO-Gate:
///   <secret>` added, which Playwright's preload (`RemoteBrowser.gateCheckJS`)
///   requires, so programs on this Mac can't skip the gate by connecting to
///   Playwright's port directly.
/// Responses are relayed untouched.
final class TokenGate: @unchecked Sendable {
    static let deniedTools: Set<String> = ["browser_run_code_unsafe"]
    static let maxHead = 64 * 1024
    static let maxBody = 16 << 20
    private static let maxConnections = 64
    private static let firstRequestTimeout: TimeInterval = 10

    private let listener: NWListener
    private let queue = DispatchQueue(label: "agent-organizer.token-gate")
    private let upstream: NWEndpoint.Port
    private let secret: String
    // Queue-only state.
    private var expected: [UInt8] = [] // empty = refuse everything
    private var open = 0

    /// `onReady` fires once the port is bound; nothing should forward to it before.
    init?(port: Int, upstream: Int, secret: String,
          onReady: @escaping @Sendable () -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        guard let local = NWEndpoint.Port(rawValue: UInt16(port)), let up = NWEndpoint.Port(rawValue: UInt16(upstream)) else { return nil }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: local) // never off-box
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else { return nil }
        self.listener = listener
        self.upstream = up
        self.secret = secret
        listener.stateUpdateHandler = {
            switch $0 {
            case .ready: onReady()
            case .failed(let e): onFailure("\(e)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: queue)
    }

    func cancel() { listener.cancel() }

    /// A fresh token per tunnel start; requests with an older one get 401.
    func setToken(_ token: String) {
        queue.async { self.expected = Array("Bearer \(token)".utf8) }
    }

    // MARK: Connections

    private final class Pair: @unchecked Sendable {
        let client: NWConnection
        var server: NWConnection?
        var buffer = Data()
        var eof = false
        var authorized = false
        init(_ client: NWConnection) { self.client = client }
        func close() { client.cancel(); server?.cancel() }
    }

    private func accept(_ client: NWConnection) {
        guard open < Self.maxConnections else { client.cancel(); return }
        open += 1
        let pair = Pair(client)
        client.stateUpdateHandler = { [self] state in
            switch state {
            case .failed: pair.close()
            case .cancelled: open -= 1; pair.server?.cancel()
            default: break
            }
        }
        client.start(queue: queue)
        // Idle connections that never authenticate would otherwise hold a descriptor each.
        queue.asyncAfter(deadline: .now() + Self.firstRequestTimeout) { if !pair.authorized { pair.close() } }
        next(pair)
    }

    /// Handles every complete request in the buffer, then reads more.
    private func next(_ pair: Pair) {
        switch Self.parse(pair.buffer, expected: expected, forwardHost: "127.0.0.1:\(upstream.rawValue)", secret: secret) {
        case .invalid(let status):
            deny(pair, status)
        case .request(let forward, let consumed):
            pair.buffer.removeFirst(consumed)
            pair.authorized = true
            send(forward, for: pair)
            next(pair)
        case .incomplete:
            if pair.eof { pair.close(); return }
            pair.client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
                if let data { pair.buffer.append(data) }
                if error != nil { pair.close(); return }
                if done { pair.eof = true }
                next(pair)
            }
        }
    }

    private func send(_ data: Data, for pair: Pair) {
        if pair.server == nil {
            let server = NWConnection(host: "127.0.0.1", port: upstream, using: .tcp)
            pair.server = server
            server.stateUpdateHandler = { if case .failed = $0 { pair.close() } }
            server.start(queue: queue)
            relay(server, to: pair)
        }
        pair.server?.send(content: data, completion: .contentProcessed { _ in })
    }

    /// Upstream → client, untouched. Upstream closing ends the pair.
    private func relay(_ server: NWConnection, to pair: Pair) {
        server.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, error in
            if let data, !data.isEmpty { pair.client.send(content: data, completion: .contentProcessed { _ in }) }
            if done || error != nil {
                pair.client.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                 completion: .contentProcessed { _ in pair.close() })
            } else {
                relay(server, to: pair)
            }
        }
    }

    private func deny(_ pair: Pair, _ status: Int) {
        let reason = [400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                      413: "Content Too Large", 417: "Expectation Failed", 431: "Request Header Fields Too Large",
                      505: "HTTP Version Not Supported"][status] ?? "Error"
        let body = status == 403 ? "This tool is disabled by Agent Organizer." : ""
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        pair.client.send(content: Data(response.utf8), completion: .contentProcessed { _ in pair.close() })
    }

    // MARK: Parsing (pure, see selfCheck)

    enum Parsed: Equatable {
        case incomplete
        case invalid(Int)                       // HTTP status to answer with, then close
        case request(forward: Data, consumed: Int)
    }

    /// One request from the front of `buffer`, rebuilt for upstream.
    static func parse(_ buffer: Data, expected: [UInt8], forwardHost: String, secret: String) -> Parsed {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHead ? .invalid(431) : .incomplete
        }
        let headLength = end.lowerBound - buffer.startIndex
        guard headLength <= maxHead else { return .invalid(431) }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid(400) }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3 else { return .invalid(400) }
        let method = String(requestLine[0]), target = String(requestLine[1])
        // Visible ASCII only: don't depend on Node's parser to reject odd targets.
        guard target.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else { return .invalid(400) }
        guard requestLine[2] == "HTTP/1.1" else { return .invalid(505) }
        guard ["GET", "POST", "DELETE"].contains(method) else { return .invalid(405) }

        var headers: [(name: String, value: String)] = []
        for line in lines {
            // Stray CR/LF/NUL or folded lines: parsers disagree on those, so refuse.
            guard !line.isEmpty, !line.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }),
                  let first = line.first, first != " ", first != "\t",
                  let colon = line.firstIndex(of: ":") else { return .invalid(400) }
            let name = String(line[..<colon])
            guard !name.isEmpty, !name.contains(where: { $0 == " " || $0 == "\t" }) else { return .invalid(400) }
            headers.append((name.lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))))
        }
        func values(_ name: String) -> [String] { headers.filter { $0.name == name }.map(\.value) }

        // Auth on every request, constant time: the remote could otherwise probe the token byte by byte.
        let auth = values("authorization")
        guard !expected.isEmpty, auth.count == 1 else { return .invalid(401) }
        let given = Array(auth[0].utf8)
        guard given.count == expected.count, zip(given, expected).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else { return .invalid(401) }

        guard target == "/mcp" || target.hasPrefix("/mcp?") else { return .invalid(404) }
        guard values("transfer-encoding").isEmpty else { return .invalid(400) }
        guard values("expect").isEmpty else { return .invalid(417) }
        let lengths = values("content-length")
        guard lengths.count <= 1 else { return .invalid(400) }
        var length = 0
        if let raw = lengths.first {
            guard !raw.isEmpty, raw.count <= 9, raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber), let n = Int(raw) else { return .invalid(400) }
            guard n <= maxBody else { return .invalid(413) }
            length = n
        }
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let body = buffer[bodyStart..<(bodyStart + length)]

        var forwardBody = Data()
        if length > 0 {
            guard let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return .invalid(400) }
            if message["method"] as? String == "tools/call", let params = message["params"] as? [String: Any] {
                if let name = params["name"] as? String, deniedTools.contains(name) { return .invalid(403) }
                // Without a filename, output still lands in the output dir under a generated name.
                if (params["arguments"] as? [String: Any])?["filename"] != nil { return .invalid(403) }
            }
            guard let encoded = try? JSONSerialization.data(withJSONObject: message) else { return .invalid(400) }
            forwardBody = encoded
        }

        let dropped: Set<String> = ["host", "authorization", "content-length", "x-ao-gate", "upgrade"]
        var out = "\(method) \(target) HTTP/1.1\r\nHost: \(forwardHost)\r\nX-AO-Gate: \(secret)\r\n"
        for (name, value) in headers where !dropped.contains(name) { out += "\(name): \(value)\r\n" }
        if method != "GET" || !forwardBody.isEmpty { out += "Content-Length: \(forwardBody.count)\r\n" }
        out += "\r\n"
        return .request(forward: Data(out.utf8) + forwardBody, consumed: bodyStart + length - buffer.startIndex)
    }

    /// Debug-build self-check (no test target in this package).
    static func selfCheck() {
        let token = Array("Bearer t0k3n".utf8)
        func req(_ head: String, _ body: String = "") -> Data { Data((head + "\r\n\r\n" + body).utf8) }
        func run(_ d: Data) -> Parsed { parse(d, expected: token, forwardHost: "127.0.0.1:9", secret: "s3cr3t") }
        func post(_ body: String, auth: String = "Bearer t0k3n") -> Parsed {
            run(req("POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: \(auth)\r\nContent-Length: \(body.utf8.count)", body))
        }
        let ok = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browser_navigate"}}"#
        guard case .request(let fwd, let used) = post(ok) else { return assertionFailure("allowed call refused") }
        let text = String(decoding: fwd, as: UTF8.self)
        assert(text.contains("Host: 127.0.0.1:9\r\n") && text.contains("X-AO-Gate: s3cr3t\r\n") && !text.lowercased().contains("authorization"))
        assert(used == req("POST /mcp HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer t0k3n\r\nContent-Length: \(ok.utf8.count)", ok).count)
        assert(post(ok, auth: "Bearer wrong") == .invalid(401))
        assert(parse(req("GET /mcp HTTP/1.1\r\nAuthorization: Bearer "), expected: [], forwardHost: "h", secret: "s") == .invalid(401))
        assert(post(#"{"method":"tools/call","params":{"name":"browser_run_code_unsafe"}}"#) == .invalid(403))
        assert(post(#"{"method":"tools/call","params":{"name":"browser_run_code_\u0075nsafe"}}"#) == .invalid(403)) // escapes decode first
        assert(post(#"{"method":"tools/call","params":{"name":"browser_take_screenshot","arguments":{"filename":".npmrc"}}}"#) == .invalid(403))
        guard case .request = post(#"{"method":"tools/call","params":{"name":"browser_take_screenshot","arguments":{}}}"#) else { return assertionFailure("screenshot refused") }
        assert(run(req("GET /mcp?\u{7f} HTTP/1.1\r\nAuthorization: Bearer t0k3n")) == .invalid(400))
        assert(post(#"[{"method":"tools/call","params":{"name":"browser_run_code_unsafe"}}]"#) == .invalid(400)) // batches refused
        assert(run(req("POST /mcp HTTP/1.1\r\nAuthorization: Bearer t0k3n\r\nTransfer-Encoding: chunked")) == .invalid(400))
        assert(run(req("POST /other HTTP/1.1\r\nAuthorization: Bearer t0k3n")) == .invalid(404))
        assert(run(req("GET /mcp HTTP/1.0\r\nAuthorization: Bearer t0k3n")) == .invalid(505))
        assert(run(req("POST /mcp HTTP/1.1\r\nAuthorization: Bearer t0k3n\r\nContent-Length: 5", "{}")) == .incomplete)
        assert(run(Data("POST /mcp HTTP/1.1\r\nAuthorization: Bearer t0k3n\r\n".utf8)) == .incomplete)
        assert(run(req("POST /mcp HTTP/1.1\r\nAuthorization: Bearer t0k3n\r\n folded")) == .invalid(400))
        // Two pipelined requests: the first is consumed alone.
        let two = req("GET /mcp HTTP/1.1\r\nAuthorization: Bearer t0k3n") + req("GET /mcp HTTP/1.1\r\nAuthorization: Bearer t0k3n")
        guard case .request(_, let first) = run(two) else { return assertionFailure("pipelined GET refused") }
        assert(first == two.count / 2)
    }
}
