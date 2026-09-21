import Foundation

/// Append-only diagnostics for the hook → notification path, at
/// Application Support/hooks.log. Tiny, human-readable, no rotation needed
/// at this volume (a few lines per Claude turn).
enum HookLog {
    static var url: URL { Store.appSupportDirectory().appendingPathComponent("hooks.log") }

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
