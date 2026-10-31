import Foundation
import Observation

struct ResourceUsage {
    var cpuPercent: Double
    var memoryBytes: Int64
    var processCount: Int

    static let zero = ResourceUsage(cpuPercent: 0, memoryBytes: 0, processCount: 0)

    var isNegligible: Bool { cpuPercent < 0.1 && memoryBytes < 10 * 1_048_576 }

    var compactLabel: String {
        let cpu = cpuPercent < 10
            ? String(format: "%.1f%%", cpuPercent)
            : String(format: "%.0f%%", cpuPercent)
        let mem: String
        if memoryBytes >= 1_073_741_824 {
            mem = String(format: "%.1fG", Double(memoryBytes) / 1_073_741_824)
        } else {
            mem = String(format: "%.0fM", Double(memoryBytes) / 1_048_576)
        }
        return "\(cpu) · \(mem)"
    }
}

/// Polls process stats for every tmux pane on the app's socket and
/// aggregates CPU + RSS across each pane's full process tree.
@MainActor
@Observable
final class ResourceMonitor {
    private(set) var usageBySession: [String: ResourceUsage] = [:]
    private var timer: Timer?
    private weak var tmux: TmuxController?

    func start(tmux: TmuxController) {
        self.tmux = tmux
        timer?.invalidate()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard let tmux else { return }
        let sessionPids = tmux.panePids()
        guard !sessionPids.isEmpty else {
            usageBySession = [:]
            return
        }

        let processes = Self.allProcesses()

        var children: [pid_t: [pid_t]] = [:]
        for proc in processes.values {
            children[proc.ppid, default: []].append(proc.pid)
        }

        var result: [String: ResourceUsage] = [:]
        for (session, rootPid) in sessionPids {
            var cpu = 0.0
            var rss: Int64 = 0
            var count = 0
            var stack = [rootPid]
            while let pid = stack.popLast() {
                if let proc = processes[pid] {
                    cpu += proc.cpu
                    rss += proc.rss
                    count += 1
                }
                if let kids = children[pid] { stack.append(contentsOf: kids) }
            }
            result[session] = ResourceUsage(cpuPercent: cpu, memoryBytes: rss, processCount: count)
        }
        usageBySession = result
    }

    private struct ProcessInfo {
        var pid: pid_t
        var ppid: pid_t
        var cpu: Double
        var rss: Int64
    }

    private static func allProcesses() -> [pid_t: ProcessInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid=,ppid=,pcpu=,rss="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var map: [pid_t: ProcessInfo] = [:]
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard cols.count == 4,
                  let pid = pid_t(cols[0]),
                  let ppid = pid_t(cols[1]),
                  let cpu = Double(cols[2]),
                  let rssKB = Int64(cols[3])
            else { continue }
            map[pid] = ProcessInfo(pid: pid, ppid: ppid, cpu: cpu, rss: rssKB * 1024)
        }
        return map
    }
}
