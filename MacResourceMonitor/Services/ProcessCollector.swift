import Foundation
import Darwin

private let kMaxPathSize: Int32 = 4 * Int32(MAXPATHLEN)

final class ProcessCollector {

    private static let maxTopProcesses = 30

    func collect() -> [ProcessMetrics] {
        let pids = listPIDs()
        var rawProcesses: [(pid: Int32, name: String, appName: String, user: String, cpu: Double, mem: UInt64)] = []

        for pid in pids {
            guard pid > 0 else { continue }

            var taskInfo = proc_taskinfo()
            let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskInfoSize)
            guard result == taskInfoSize else { continue }

            let name = processName(for: pid)
            guard !name.isEmpty else { continue }

            let appName = groupName(for: pid, processName: name)
            let user = processUser(for: pid)

            let totalTimeNs = taskInfo.pti_total_user + taskInfo.pti_total_system
            let totalTimeSec = Double(totalTimeNs) / 1_000_000_000.0

            let memBytes = taskInfo.pti_resident_size

            rawProcesses.append((pid: pid, name: name, appName: appName, user: user, cpu: totalTimeSec, mem: memBytes))
        }

        // Group by application name
        var groups: [String: [(pid: Int32, name: String, user: String, cpu: Double, mem: UInt64)]] = [:]
        for proc in rawProcesses {
            groups[proc.appName, default: []].append((proc.pid, proc.name, proc.user, proc.cpu, proc.mem))
        }

        // Build grouped ProcessMetrics
        var results: [ProcessMetrics] = []
        for (appName, members) in groups {
            let totalCPU = members.reduce(0.0) { $0 + $1.cpu }
            let totalMem = members.reduce(UInt64(0)) { $0 + $1.mem }
            let primaryUser = members.max(by: { $0.cpu < $1.cpu })?.user ?? members[0].user

            if members.count == 1 {
                let m = members[0]
                results.append(ProcessMetrics(
                    pid: m.pid,
                    name: appName,
                    user: m.user,
                    bundleIdentifier: nil,
                    cpuUsage: m.cpu,
                    memoryBytes: m.mem,
                    isGroup: false,
                    children: []
                ))
            } else {
                let children = members.map { m in
                    ProcessMetrics(
                        pid: m.pid,
                        name: m.name,
                        user: m.user,
                        bundleIdentifier: nil,
                        cpuUsage: m.cpu,
                        memoryBytes: m.mem,
                        isGroup: false,
                        children: []
                    )
                }
                let topPID = members.max(by: { $0.cpu < $1.cpu })?.pid ?? members[0].pid
                results.append(ProcessMetrics(
                    pid: topPID,
                    name: appName,
                    user: primaryUser,
                    bundleIdentifier: nil,
                    cpuUsage: totalCPU,
                    memoryBytes: totalMem,
                    isGroup: true,
                    children: children
                ))
            }
        }

        // Sort by CPU descending and take top N
        results.sort { $0.cpuUsage > $1.cpuUsage }
        return Array(results.prefix(Self.maxTopProcesses))
    }

    // MARK: - Private helpers

    private func listPIDs() -> [Int32] {
        // First call to get the buffer size needed
        let estimatedCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard estimatedCount > 0 else { return [] }

        let bufferSize = estimatedCount
        var pids = [Int32](repeating: 0, count: Int(bufferSize) / MemoryLayout<Int32>.size)
        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        guard actualSize > 0 else { return [] }

        let count = Int(actualSize) / MemoryLayout<Int32>.size
        return Array(pids.prefix(count))
    }

    private func processUser(for pid: Int32) -> String {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return "unknown" }
        let uid = info.kp_eproc.e_ucred.cr_uid
        if let pw = getpwuid(uid) {
            return String(cString: pw.pointee.pw_name)
        }
        return "\(uid)"
    }

    private func processName(for pid: Int32) -> String {
        // Try proc_pidpath first for a full path, then extract the executable name
        var pathBuffer = [CChar](repeating: 0, count: Int(kMaxPathSize))
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(kMaxPathSize))
        if pathLen > 0 {
            let fullPath = String(cString: pathBuffer)
            return (fullPath as NSString).lastPathComponent
        }

        // Fallback to proc_name
        var nameBuffer = [CChar](repeating: 0, count: Int(kMaxPathSize))
        proc_name(pid, &nameBuffer, UInt32(kMaxPathSize))
        let name = String(cString: nameBuffer)
        return name
    }

    /// Groups helper processes under their parent application name.
    /// E.g., "Google Chrome Helper (Renderer)" -> "Google Chrome"
    private func groupName(for pid: Int32, processName name: String) -> String {
        // Try to derive app name from the full path (look for .app bundle)
        var pathBuffer = [CChar](repeating: 0, count: Int(kMaxPathSize))
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(kMaxPathSize))
        if pathLen > 0 {
            let fullPath = String(cString: pathBuffer)
            // Look for a .app bundle in the path
            if let appRange = fullPath.range(of: "/[^/]+\\.app/", options: String.CompareOptions.regularExpression) {
                let appComponent = fullPath[appRange].dropFirst(1).dropLast(1) // Remove leading / and trailing /
                let appName = appComponent.replacingOccurrences(of: ".app", with: "")
                return appName
            }
        }

        // Strip common helper suffixes for grouping
        let helperPatterns = [" Helper (Renderer)", " Helper (GPU)", " Helper (Plugin)", " Helper"]
        for pattern in helperPatterns {
            if name.hasSuffix(pattern) {
                return String(name.dropLast(pattern.count))
            }
        }

        return name
    }
}
