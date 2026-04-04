import Foundation
import IOKit

final class GPUCollector {

    func collect() -> GPUMetrics {
        let timestamp = Date()

        // Query IOAccelerator for GPU utilization on Apple Silicon
        var utilization = 0.0
        var gpuCoreCount = 0

        let matchDict = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)

        if result == KERN_SUCCESS {
            var service = IOIteratorNext(iterator)
            while service != 0 {
                var properties: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = properties?.takeRetainedValue() as? [String: Any] {

                    // "PerformanceStatistics" contains GPU utilization data
                    if let perfStats = dict["PerformanceStatistics"] as? [String: Any] {
                        // Different keys depending on GPU generation
                        if let gpuUtil = perfStats["GPU Activity(%)"] as? NSNumber {
                            utilization = gpuUtil.doubleValue
                        } else if let deviceUtil = perfStats["Device Utilization %"] as? NSNumber {
                            utilization = deviceUtil.doubleValue
                        } else if let gpuActivity = perfStats["gpuActivity"] as? NSNumber {
                            utilization = gpuActivity.doubleValue
                        }

                        if let cores = perfStats["GPU Core Count"] as? Int {
                            gpuCoreCount = cores
                        }
                    }

                    // Fallback: try to get core count from top-level properties
                    if gpuCoreCount == 0, let cores = dict["gpu-core-count"] as? Int {
                        gpuCoreCount = cores
                    }
                }

                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }

        // Default core count for M3 Ultra if not reported
        if gpuCoreCount == 0 {
            gpuCoreCount = 80
        }

        return GPUMetrics(
            timestamp: timestamp,
            utilizationPercent: utilization,
            coreCount: gpuCoreCount,
            perCoreUsage: nil
        )
    }
}
