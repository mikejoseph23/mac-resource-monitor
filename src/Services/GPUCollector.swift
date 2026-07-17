import Foundation
import IOKit

final class GPUCollector {

    /// UserDefaults key for the optional user-set GPU core-count override
    /// (Settings, #13). A value of 0 (the `integer(forKey:)` default when
    /// unset) means "no override — use the detected/tier value". Read here on
    /// the collector's own actor executor so the setting flows in without any
    /// cross-actor plumbing; `UserDefaults` reads are thread-safe.
    static let coreCountOverrideKey = "settings.gpuCoreCountOverride"

    private lazy var chipName: String = Self.detectChipName()
    private lazy var neuralEngineCores: Int = Self.neuralEngineCoreCount(for: chipName)

    func collect() -> GPUMetrics {
        let timestamp = Date()

        // Query IOAccelerator for GPU utilization on Apple Silicon
        var utilization = 0.0
        var gpuCoreCount = 0

        let matchDict = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)

        if result == KERN_SUCCESS {
            // Multiple IOAccelerator entries can be enumerated (e.g. a Mac with
            // more than one GPU). Take the first entry that actually reports
            // PerformanceStatistics as the primary accelerator instead of
            // letting whichever node enumerates last silently win.
            var service = IOIteratorNext(iterator)
            var foundPrimaryAccelerator = false
            while service != 0 {
                if !foundPrimaryAccelerator {
                    var properties: Unmanaged<CFMutableDictionary>?
                    if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                       let dict = properties?.takeRetainedValue() as? [String: Any],
                       let perfStats = dict["PerformanceStatistics"] as? [String: Any] {

                        foundPrimaryAccelerator = true

                        let parsed = Self.parseAcceleratorStats(perfStats: perfStats, topLevelDict: dict)
                        utilization = parsed.utilization
                        gpuCoreCount = parsed.coreCount
                    }
                }

                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }

        let override = UserDefaults.standard.integer(forKey: Self.coreCountOverrideKey)
        gpuCoreCount = Self.resolveCoreCount(reported: gpuCoreCount, override: override, chip: chipName)

        return GPUMetrics(
            timestamp: timestamp,
            utilizationPercent: utilization,
            coreCount: gpuCoreCount,
            perCoreUsage: nil,
            chipName: chipName,
            neuralEngineCoreCount: neuralEngineCores
        )
    }

    /// Parses IOAccelerator's PerformanceStatistics dict for utilization and
    /// core count. IORegistry integer properties bridge to Swift as NSNumber,
    /// not Int — `as? Int` silently fails, so we must go through NSNumber.
    static func parseAcceleratorStats(
        perfStats: [String: Any],
        topLevelDict: [String: Any]
    ) -> (utilization: Double, coreCount: Int) {
        var utilization = 0.0
        var coreCount = 0

        // Different keys depending on GPU generation
        if let gpuUtil = perfStats["GPU Activity(%)"] as? NSNumber {
            utilization = gpuUtil.doubleValue
        } else if let deviceUtil = perfStats["Device Utilization %"] as? NSNumber {
            utilization = deviceUtil.doubleValue
        } else if let gpuActivity = perfStats["gpuActivity"] as? NSNumber {
            utilization = gpuActivity.doubleValue
        }

        if let cores = perfStats["GPU Core Count"] as? NSNumber {
            coreCount = cores.intValue
        } else if let cores = topLevelDict["gpu-core-count"] as? NSNumber {
            coreCount = cores.intValue
        }

        return (utilization, coreCount)
    }

    /// Resolves the GPU core count from three sources, in priority order:
    /// 1. an explicit user override (Settings #13) when set (> 0) — the user
    ///    knows their exact hardware, so it wins even over an IOKit reading;
    /// 2. the value IOKit actually reported (> 0);
    /// 3. the hardcoded/tier default for the chip (QA #7 fallback).
    /// A non-positive `override` means "unset" and behavior is unchanged.
    static func resolveCoreCount(reported: Int, override: Int, chip: String) -> Int {
        if override > 0 { return override }
        if reported > 0 { return reported }
        return defaultGPUCoreCount(for: chip)
    }

    private static func detectChipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let raw = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "Apple Silicon" : raw
    }

    private static func neuralEngineCoreCount(for chip: String) -> Int {
        // All current Apple Silicon has a 16-core Neural Engine; Ultra variants
        // fuse two dies and double it to 32. Older A-series could be lower, but
        // we target macOS 14+ / Apple Silicon Macs, so 16/32 covers the field.
        return chip.localizedCaseInsensitiveContains("Ultra") ? 32 : 16
    }

    private static func defaultGPUCoreCount(for chip: String) -> Int {
        // Hardcoded per-chip core counts for when IOKit doesn't report one.
        // Kept in sync manually as new chips ship; unlisted chips (e.g. a
        // future M5 family) fall through to the tier-based estimate below
        // rather than a hard 0.
        let lower = chip.lowercased()
        if lower.contains("m3 ultra") { return 80 }
        if lower.contains("m2 ultra") { return 76 }
        if lower.contains("m1 ultra") { return 64 }
        if lower.contains("m4 max")   { return 40 }
        if lower.contains("m3 max")   { return 40 }
        if lower.contains("m2 max")   { return 38 }
        if lower.contains("m1 max")   { return 32 }
        if lower.contains("m4 pro")   { return 20 }
        if lower.contains("m3 pro")   { return 18 }
        if lower.contains("m2 pro")   { return 19 }
        if lower.contains("m1 pro")   { return 16 }
        if lower.contains("m4")       { return 10 }
        if lower.contains("m3")       { return 10 }
        if lower.contains("m2")       { return 10 }
        if lower.contains("m1")       { return 8 }

        // Unlisted/future chip: estimate from the variant suffix using the
        // most recent known tier sizes so gauges show a plausible non-zero
        // value instead of reading 0.
        if lower.contains("ultra") { return 80 }
        if lower.contains("max")   { return 40 }
        if lower.contains("pro")   { return 20 }
        return 10
    }
}
