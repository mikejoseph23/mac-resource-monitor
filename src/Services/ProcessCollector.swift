import Foundation
import Darwin

private let kMaxPathSize: Int32 = 4 * Int32(MAXPATHLEN)

/// Identifies a process across samples. PIDs are recycled by the kernel, so
/// pairing a PID with its process start time keeps a delta calculation from
/// diffing a freshly-spawned process against a dead one that happened to
/// share the same PID.
private struct ProcessIdentity: Hashable {
    let pid: Int32
    let startTimeKey: UInt64
}

final class ProcessCollector {

    /// Previous sample of per-process cumulative CPU time (nanoseconds), keyed by PID + start time
    private var previousCPUTimes: [ProcessIdentity: UInt64] = [:]
    private var previousSampleTime: Date?

    func collect() -> [ProcessMetrics] {
        let now = Date()
        let elapsed = previousSampleTime.map { now.timeIntervalSince($0) } ?? 0
        let pids = listPIDs()
        var currentCPUTimes: [ProcessIdentity: UInt64] = [:]
        var rawProcesses: [(pid: Int32, name: String, appName: String, user: String, cpu: Double, mem: UInt64)] = []

        for pid in pids {
            guard pid > 0 else { continue }

            // Try detailed task info first (works for same-user processes)
            var taskInfo = proc_taskinfo()
            let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskInfoSize)

            if result == taskInfoSize {
                // Got detailed info — compute CPU % from delta
                let name = processName(for: pid)
                guard !name.isEmpty else { continue }

                let appName = groupName(for: pid, processName: name)
                let user = processUser(for: pid)
                let identity = ProcessIdentity(pid: pid, startTimeKey: processStartTimeKey(for: pid))

                let totalTimeNs = taskInfo.pti_total_user + taskInfo.pti_total_system
                currentCPUTimes[identity] = totalTimeNs

                var cpuPercent = 0.0
                if elapsed > 0, let prevTime = previousCPUTimes[identity] {
                    let deltaNs = totalTimeNs > prevTime ? totalTimeNs - prevTime : 0
                    let deltaSec = Double(deltaNs) / 1_000_000_000.0
                    cpuPercent = (deltaSec / elapsed) * 100.0
                }

                rawProcesses.append((pid: pid, name: name, appName: appName, user: user, cpu: cpuPercent, mem: taskInfo.pti_resident_size))
            } else {
                // Fallback: use sysctl kinfo_proc for basic info (works for all processes)
                guard let kinfo = kinfoForPID(pid) else { continue }
                // Skip zombies and processes with empty names
                guard kinfo.kp_proc.p_stat != 5 else { continue } // SZOMB

                let name = processNameFromKinfo(kinfo, pid: pid)
                guard !name.isEmpty else { continue }

                let appName = groupName(for: pid, processName: name)
                let user = userFromKinfo(kinfo)

                rawProcesses.append((pid: pid, name: name, appName: appName, user: user, cpu: 0, mem: 0))
            }
        }

        previousCPUTimes = currentCPUTimes
        previousSampleTime = now

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

        // Sort by CPU descending
        results.sort { $0.cpuUsage > $1.cpuUsage }
        return results
    }

    // MARK: - Private helpers

    private func listPIDs() -> [Int32] {
        let estimatedCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard estimatedCount > 0 else { return [] }

        let bufferSize = estimatedCount
        var pids = [Int32](repeating: 0, count: Int(bufferSize) / MemoryLayout<Int32>.size)
        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        guard actualSize > 0 else { return [] }

        let count = Int(actualSize) / MemoryLayout<Int32>.size
        return Array(pids.prefix(count))
    }

    private func kinfoForPID(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info
    }

    /// Process start time as microseconds since epoch, used to disambiguate
    /// a recycled PID from the process that previously held it. Returns 0
    /// (never matches a real process) if the lookup fails.
    private func processStartTimeKey(for pid: Int32) -> UInt64 {
        var bsdInfo = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, size) == size else { return 0 }
        return UInt64(bsdInfo.pbi_start_tvsec) * 1_000_000 + UInt64(bsdInfo.pbi_start_tvusec)
    }

    private func processUser(for pid: Int32) -> String {
        guard let info = kinfoForPID(pid) else { return "unknown" }
        return userFromKinfo(info)
    }

    private func userFromKinfo(_ info: kinfo_proc) -> String {
        let uid = info.kp_eproc.e_ucred.cr_uid
        if let pw = getpwuid(uid) {
            return String(cString: pw.pointee.pw_name)
        }
        return "\(uid)"
    }

    private func processName(for pid: Int32) -> String {
        var pathBuffer = [CChar](repeating: 0, count: Int(kMaxPathSize))
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(kMaxPathSize))
        if pathLen > 0 {
            let fullPath = String(cString: pathBuffer)
            return (fullPath as NSString).lastPathComponent
        }

        var nameBuffer = [CChar](repeating: 0, count: Int(kMaxPathSize))
        proc_name(pid, &nameBuffer, UInt32(kMaxPathSize))
        let name = String(cString: nameBuffer)
        return name
    }

    private func processNameFromKinfo(_ info: kinfo_proc, pid: Int32) -> String {
        // Try proc_pidpath first (may work even when PROC_PIDTASKINFO fails)
        var pathBuffer = [CChar](repeating: 0, count: Int(kMaxPathSize))
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(kMaxPathSize))
        if pathLen > 0 {
            let fullPath = String(cString: pathBuffer)
            return (fullPath as NSString).lastPathComponent
        }

        // Try proc_name
        var nameBuffer = [CChar](repeating: 0, count: Int(kMaxPathSize))
        proc_name(pid, &nameBuffer, UInt32(kMaxPathSize))
        let procName = String(cString: nameBuffer)
        if !procName.isEmpty { return procName }

        // Last resort: kinfo_proc p_comm (16 char limit)
        var comm = info.kp_proc.p_comm
        let name = withUnsafePointer(to: &comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                String(cString: $0)
            }
        }
        return name
    }

    /// Groups helper processes under their parent application name.
    private func groupName(for pid: Int32, processName name: String) -> String {
        var pathBuffer = [CChar](repeating: 0, count: Int(kMaxPathSize))
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(kMaxPathSize))
        if pathLen > 0 {
            let fullPath = String(cString: pathBuffer)
            if let appRange = fullPath.range(of: "/[^/]+\\.app/", options: String.CompareOptions.regularExpression) {
                let appComponent = fullPath[appRange].dropFirst(1).dropLast(1)
                let appName = appComponent.replacingOccurrences(of: ".app", with: "")
                return appName
            }
        }

        let helperPatterns = [" Helper (Renderer)", " Helper (GPU)", " Helper (Plugin)", " Helper"]
        for pattern in helperPatterns {
            if name.hasSuffix(pattern) {
                return String(name.dropLast(pattern.count))
            }
        }

        return name
    }
}
