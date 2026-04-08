import Foundation
import Darwin

final class CPUCollector {
    private var previousTicks: [UInt64]? // [user, system, idle, nice] per core flattened

    func collect() -> CPUMetrics {
        let timestamp = Date()
        var numCPUsU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUsU,
            &cpuInfo,
            &cpuInfoCount
        )

        guard result == KERN_SUCCESS, let info = cpuInfo else {
            return CPUMetrics(
                timestamp: timestamp,
                totalUsage: 0, userUsage: 0, systemUsage: 0, idleUsage: 100,
                coreCount: 0, perCoreUsage: [],
                threadCount: 0, processCount: 0
            )
        }

        let numCPUs = Int(numCPUsU)
        // Each core has CPU_STATE_MAX (4) entries: user, system, idle, nice
        let stateCount = Int(CPU_STATE_MAX)

        // Read current ticks
        var currentTicks = [UInt64](repeating: 0, count: numCPUs * stateCount)
        for core in 0..<numCPUs {
            let base = core * stateCount
            let infoBase = Int32(core) * CPU_STATE_MAX
            currentTicks[base + 0] = UInt64(info[Int(infoBase + CPU_STATE_USER)])
            currentTicks[base + 1] = UInt64(info[Int(infoBase + CPU_STATE_SYSTEM)])
            currentTicks[base + 2] = UInt64(info[Int(infoBase + CPU_STATE_IDLE)])
            currentTicks[base + 3] = UInt64(info[Int(infoBase + CPU_STATE_NICE)])
        }

        // Deallocate the processor info
        let deallocSize = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), deallocSize)

        // Calculate deltas
        var perCoreUsage = [Double](repeating: 0, count: numCPUs)
        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var totalIdle: UInt64 = 0

        if let prev = previousTicks, prev.count == currentTicks.count {
            for core in 0..<numCPUs {
                let base = core * stateCount
                let dUser = currentTicks[base + 0] - prev[base + 0]
                let dSystem = currentTicks[base + 1] - prev[base + 1]
                let dIdle = currentTicks[base + 2] - prev[base + 2]
                let dNice = currentTicks[base + 3] - prev[base + 3]
                let total = dUser + dSystem + dIdle + dNice

                totalUser += dUser + dNice
                totalSystem += dSystem
                totalIdle += dIdle

                if total > 0 {
                    perCoreUsage[core] = Double(dUser + dSystem + dNice) / Double(total) * 100.0
                }
            }
        }

        previousTicks = currentTicks

        let grandTotal = totalUser + totalSystem + totalIdle
        let userPct: Double
        let systemPct: Double
        let idlePct: Double

        if grandTotal > 0 {
            userPct = Double(totalUser) / Double(grandTotal) * 100.0
            systemPct = Double(totalSystem) / Double(grandTotal) * 100.0
            idlePct = Double(totalIdle) / Double(grandTotal) * 100.0
        } else {
            userPct = 0
            systemPct = 0
            idlePct = 100
        }

        // Get process and thread counts
        let processCount = Self.getProcessCount()
        let threadCount = Self.getThreadCount()

        return CPUMetrics(
            timestamp: timestamp,
            totalUsage: userPct + systemPct,
            userUsage: userPct,
            systemUsage: systemPct,
            idleUsage: idlePct,
            coreCount: numCPUs,
            perCoreUsage: perCoreUsage,
            threadCount: threadCount,
            processCount: processCount
        )
    }

    /// Returns the number of running processes using proc_listpids.
    private static func getProcessCount() -> Int {
        // First call with nil buffer returns the buffer size needed
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return 0 }
        // Each pid is an Int32 (4 bytes)
        return Int(bufferSize) / MemoryLayout<Int32>.size
    }

    /// Returns the total number of threads via sysctl kern.num_threads if available,
    /// otherwise falls back to host_statistics.
    private static func getThreadCount() -> Int {
        var threadCount: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let ret = sysctlbyname("kern.num_threads", &threadCount, &size, nil, 0)
        if ret == 0 && threadCount > 0 {
            return Int(threadCount)
        }
        // Fallback: not available
        return 0
    }
}
