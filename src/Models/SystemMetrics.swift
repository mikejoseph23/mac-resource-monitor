import Foundation

struct CPUMetrics: Identifiable {
    let id = UUID()
    let timestamp: Date
    let totalUsage: Double        // 0.0 - 100.0
    let userUsage: Double
    let systemUsage: Double
    let idleUsage: Double
    let coreCount: Int
    let perCoreUsage: [Double]    // per-core percentages
    let threadCount: Int
    let processCount: Int
}

struct MemoryMetrics: Identifiable {
    let id = UUID()
    let timestamp: Date
    let totalBytes: UInt64
    let usedBytes: UInt64
    let freeBytes: UInt64
    let activeBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
    let cachedBytes: UInt64
    let swapUsedBytes: UInt64
    let appMemoryBytes: UInt64
    let pressureLevel: MemoryPressure

    var usagePercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100.0
    }
}

enum MemoryPressure: String {
    case nominal = "Nominal"
    case warning = "Warning"
    case critical = "Critical"
}

struct GPUMetrics: Identifiable {
    let id = UUID()
    let timestamp: Date
    let utilizationPercent: Double
    let coreCount: Int
    let perCoreUsage: [Double]?
}

struct VolumeInfo: Identifiable {
    var id: String { mountPoint }
    let name: String
    let mountPoint: String
    let totalBytes: UInt64
    let usedBytes: UInt64
    let isBootVolume: Bool

    var freeBytes: UInt64 { totalBytes - usedBytes }

    var usagePercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100.0
    }
}

struct DiskMetrics: Identifiable {
    let id = UUID()
    let timestamp: Date
    let readBytesPerSec: Double
    let writeBytesPerSec: Double
    let totalDiskSpace: UInt64
    let usedDiskSpace: UInt64
    let totalReadBytes: UInt64
    let totalWriteBytes: UInt64
    let readOpsPerSec: Double
    let writeOpsPerSec: Double
    let volumes: [VolumeInfo]
}

struct NetworkMetrics: Identifiable {
    let id = UUID()
    let timestamp: Date
    let bytesInPerSec: Double
    let bytesOutPerSec: Double
    let totalBytesIn: UInt64
    let totalBytesOut: UInt64
    let packetsInPerSec: Double
    let packetsOutPerSec: Double
}

struct ThermalMetrics: Identifiable {
    let id = UUID()
    let timestamp: Date
    let thermalState: ProcessInfo.ThermalState
    let isThrottled: Bool
}

struct ProcessMetrics: Identifiable {
    var id: String { "\(pid)-\(name)" }
    let pid: Int32
    let name: String
    let user: String
    let bundleIdentifier: String?
    let cpuUsage: Double
    let memoryBytes: UInt64
    let isGroup: Bool
    let children: [ProcessMetrics]
}

struct AppSelfMetrics {
    let cpuUsage: Double
    let memoryBytes: UInt64
}

// MARK: - LM Studio

enum LMStudioConnectionStatus {
    case offline
    case connected
}

struct LMStudioModel: Identifiable {
    var id: String { modelId }
    let modelId: String
    let type: String            // "llm", "vlm", "embeddings"
    let publisher: String
    let arch: String
    let quantization: String
    let state: String           // "loaded", "not-loaded"
    let maxContextLength: Int
    let loadedContextLength: Int?
    let compatibilityType: String  // "gguf", "mlx"

    var isLoaded: Bool { state == "loaded" }
}

struct LMStudioMetrics {
    let status: LMStudioConnectionStatus
    let models: [LMStudioModel]

    var loadedModels: [LMStudioModel] { models.filter(\.isLoaded) }
    var availableCount: Int { models.count }
    var loadedCount: Int { loadedModels.count }

    static let offline = LMStudioMetrics(status: .offline, models: [])
}

struct SystemSnapshot: Identifiable {
    let id = UUID()
    let timestamp: Date
    let cpu: CPUMetrics
    let memory: MemoryMetrics
    let gpu: GPUMetrics
    let disk: DiskMetrics
    let network: NetworkMetrics
    let thermal: ThermalMetrics
    let selfMetrics: AppSelfMetrics
    let processes: [ProcessMetrics]
    let lmStudio: LMStudioMetrics
}
