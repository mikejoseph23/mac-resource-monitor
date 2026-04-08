import Foundation
import Darwin

final class SelfMetricsCollector {
    private var previousCPUTime: TimeInterval?
    private var previousWallTime: Date?

    func collect() -> AppSelfMetrics {
        let memoryBytes = residentMemory()
        let cpuUsage = processCPUUsage()

        return AppSelfMetrics(
            cpuUsage: cpuUsage,
            memoryBytes: memoryBytes
        )
    }

    /// Resident memory of the current process via task_info
    private func residentMemory() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        if result == KERN_SUCCESS {
            return UInt64(info.phys_footprint)
        }
        return 0
    }

    /// CPU usage of the current process using CPU time deltas.
    ///
    /// The previous approach used thread_basic_info.cpu_usage which is an
    /// instantaneous snapshot that often reads 0 when the thread isn't
    /// actively running at that exact moment. Instead, we now compute
    /// (delta_cpu_time / delta_wall_time) * 100 using TASK_BASIC_INFO's
    /// cumulative user_time + system_time, which matches how Activity
    /// Monitor calculates process CPU percentages.
    private func processCPUUsage() -> Double {
        var info = task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }

        let now = Date()
        let userSec = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000.0
        let sysSec = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000.0
        let currentCPUTime = userSec + sysSec

        defer {
            previousCPUTime = currentCPUTime
            previousWallTime = now
        }

        guard let prevCPU = previousCPUTime, let prevWall = previousWallTime else {
            // First call — no delta yet, return 0
            return 0
        }

        let wallElapsed = now.timeIntervalSince(prevWall)
        guard wallElapsed > 0 else { return 0 }

        let cpuDelta = currentCPUTime - prevCPU
        return (cpuDelta / wallElapsed) * 100.0
    }
}
