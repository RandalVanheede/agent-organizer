import AppKit
import Darwin
import Observation

struct ResourceUsage {
    var cpuPercent: Double
    var memoryBytes: Int64
    var processCount: Int

    static let zero = ResourceUsage(cpuPercent: 0, memoryBytes: 0, processCount: 0)

    var isNegligible: Bool { cpuPercent < 0.1 && memoryBytes < 10 * 1_048_576 }

    /// Worth surfacing on the tab itself rather than only in its tooltip.
    var isHot: Bool { cpuPercent >= 50 || memoryBytes >= 1_073_741_824 }

    var cpuLabel: String {
        cpuPercent < 10 ? String(format: "%.1f%%", cpuPercent) : String(format: "%.0f%%", cpuPercent)
    }

    var memoryLabel: String {
        memoryBytes >= 1_073_741_824
            ? String(format: "%.1f GB", Double(memoryBytes) / 1_073_741_824)
            : String(format: "%.0f MB", Double(memoryBytes) / 1_048_576)
    }
}

/// Samples CPU + RSS for every agent's pane process tree straight from the
/// kernel (libproc) — no `ps`/`tmux` spawn. Pane PIDs come from the control
/// mode subscription. Paused while the app is in the background, where no
/// tab (and so no figure) is visible.
@MainActor
@Observable
final class ResourceMonitor {
    private(set) var usageBySession: [String: ResourceUsage] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var panePids: () -> [String: pid_t] = { [:] }
    /// CPU time (ns) per pid at the previous sample, for the delta.
    @ObservationIgnored private var lastCPU: [pid_t: UInt64] = [:]
    @ObservationIgnored private var lastSampleAt: UInt64 = 0

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    func start(panePids: @escaping () -> [String: pid_t]) {
        self.panePids = panePids
        timer?.invalidate()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        guard NSApp?.isActive ?? true else {
            // Stale deltas would be averaged over the whole background stint,
            // and old figures shouldn't linger as if current.
            lastCPU = [:]
            lastSampleAt = 0
            if !usageBySession.isEmpty { usageBySession = [:] }
            return
        }
        let roots = panePids()
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = lastSampleAt == 0 ? 0 : Double(now - lastSampleAt)
        var nextCPU: [pid_t: UInt64] = [:]
        var result: [String: ResourceUsage] = [:]

        for (session, root) in roots {
            var usage = ResourceUsage.zero
            var stack = [root]
            while let pid = stack.popLast() {
                if let (cpuNs, rss) = Self.taskInfo(pid) {
                    nextCPU[pid] = cpuNs
                    if elapsed > 0, let previous = lastCPU[pid], cpuNs >= previous {
                        usage.cpuPercent += Double(cpuNs - previous) / elapsed * 100
                    }
                    usage.memoryBytes += rss
                    usage.processCount += 1
                }
                stack.append(contentsOf: Self.children(of: pid))
            }
            result[session] = usage
        }
        lastCPU = nextCPU
        lastSampleAt = now
        usageBySession = result
    }

    /// Total CPU time (ns) and resident size of one process; nil once it's gone.
    private static func taskInfo(_ pid: pid_t) -> (UInt64, Int64)? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        // pti_total_* are mach ticks on Apple silicon, not nanoseconds.
        let ticks = info.pti_total_user + info.pti_total_system
        return (ticks * timebase.numer / timebase.denom, Int64(info.pti_resident_size))
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        // shortcut: caps at 256 direct children per process; agent trees are far smaller.
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }
}
