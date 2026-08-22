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
    let chipName: String
    let neuralEngineCoreCount: Int
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

struct PowerMetrics: Identifiable {
    let id = UUID()
    let timestamp: Date
    let cpuPowerWatts: Double
    let gpuPowerWatts: Double
    let anePowerWatts: Double
    let totalPowerWatts: Double      // cpu + gpu + ane
    let ecpuFreqMHz: Int             // 0 when no E-CPU activity
    let pcpuFreqMHz: Int
    let gpuFreqMHz: Int
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

// MARK: - oMLX

/// oMLX (app.omlx) serves MLX models from a local FastAPI server. `/health` is
/// unauthenticated and always available; `/api/status` carries the interesting
/// numbers but requires the server's API key, which we read out of
/// `~/.omlx/settings.json` — see `OMLXCollector`. `detailed` records whether
/// that richer call succeeded, so the UI can show fewer fields instead of
/// pretending zeros are real.
struct OMLXMetrics {
    enum Status {
        case offline
        case loading      // port bound, pinned models still preloading (503)
        case connected
    }

    let status: Status
    let detailed: Bool
    let version: String?
    let defaultModel: String?
    let discoveredCount: Int
    let loadedCount: Int
    let loadingCount: Int
    let loadedModels: [String]
    let modelMemoryUsedBytes: UInt64
    let modelMemoryMaxBytes: UInt64?
    let activeRequests: Int
    let waitingRequests: Int
    let generationTPS: Double?
    let prefillTPS: Double?
    let cacheEfficiency: Double?

    var isOnline: Bool { status != .offline }
    var isBusy: Bool { activeRequests > 0 || waitingRequests > 0 || loadingCount > 0 }

    var memoryFraction: Double? {
        guard let max = modelMemoryMaxBytes, max > 0 else { return nil }
        return Double(modelMemoryUsedBytes) / Double(max)
    }

    static let offline = OMLXMetrics(
        status: .offline,
        detailed: false,
        version: nil,
        defaultModel: nil,
        discoveredCount: 0,
        loadedCount: 0,
        loadingCount: 0,
        loadedModels: [],
        modelMemoryUsedBytes: 0,
        modelMemoryMaxBytes: nil,
        activeRequests: 0,
        waitingRequests: 0,
        generationTPS: nil,
        prefillTPS: nil,
        cacheEfficiency: nil
    )
}

// MARK: - Ollama

struct OllamaModel: Identifiable {
    var id: String { name }
    let name: String
    let sizeBytes: UInt64
    let vramBytes: UInt64
    let parameterSize: String?
    let quantization: String?
    let family: String?
    /// When Ollama will unload the model unless it's used again.
    let expiresAt: Date?

    /// Ollama reports total resident size and the VRAM slice separately; a
    /// partial offload is the interesting (slow) case worth surfacing.
    var isFullyOnGPU: Bool { sizeBytes > 0 && vramBytes >= sizeBytes }
}

struct OllamaMetrics {
    enum Status {
        case offline
        case connected
    }

    let status: Status
    let version: String?
    /// Models pulled to disk (from `/api/tags`), not just resident ones.
    let installedCount: Int
    let loadedModels: [OllamaModel]

    var loadedCount: Int { loadedModels.count }
    var isOnline: Bool { status != .offline }
    var residentBytes: UInt64 { loadedModels.reduce(0) { $0 + $1.sizeBytes } }

    static let offline = OllamaMetrics(status: .offline, version: nil, installedCount: 0, loadedModels: [])
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
    let power: PowerMetrics?         // nil on Intel or when IOReport is unavailable
    let selfMetrics: AppSelfMetrics
    let processes: [ProcessMetrics]
    let lmStudio: LMStudioMetrics
    let omlx: OMLXMetrics
    let ollama: OllamaMetrics
}

// MARK: - Local AI storage

/// Which local inference app wrote the data.
enum AIStorageProvider: String, CaseIterable, Identifiable {
    case lmStudio = "LM Studio"
    case omlx = "oMLX"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .lmStudio: return "bubble.left.and.text.bubble.right"
        case .omlx:     return "cube.transparent"
        }
    }
}

/// One directory on disk that a local inference app retains prompt-derived
/// data in. Immutable; produced by `AIStorageCollector.scan()`.
struct AIStorageTarget: Identifiable, Hashable {
    /// Stable across scans — the purge sheet's selection keys off it.
    let id: String
    let provider: AIStorageProvider
    /// Row label, e.g. "Server logs".
    let label: String
    /// Absolute path scanned.
    let path: String
    /// `~`-abbreviated path for display.
    let displayPath: String
    /// One line on what is actually in there. Shown in the purge sheet.
    let contents: String
    /// Short trailing annotation in the panel, e.g. "prompts, no TTL".
    let note: String?
    /// True when `note` describes a privacy hazard rather than a policy.
    let noteIsWarning: Bool
    /// False for the oMLX KV cache — binary tensors, not text-searchable.
    let isTextSearchable: Bool
    /// False when the directory doesn't exist (app not installed / never used).
    let exists: Bool
    let sizeBytes: UInt64
    let fileCount: Int
    /// Configured ceiling, when the app has one (oMLX `ssd_cache_max_size`).
    let capBytes: UInt64?
    /// The oMLX server holds this open; purging it needs the server stopped.
    let requiresOMLXStopped: Bool

    var capFraction: Double? {
        guard let capBytes, capBytes > 0 else { return nil }
        return min(Double(sizeBytes) / Double(capBytes), 1.0)
    }
}

/// The result of one storage scan. `MetricsManager`'s 2s timer never produces
/// one of these — see `AIStorageCollector` for why.
struct AIStorageSnapshot {
    let targets: [AIStorageTarget]
    let scannedAt: Date

    var totalBytes: UInt64 {
        targets.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Providers with at least one directory present on this machine.
    var presentProviders: [AIStorageProvider] {
        AIStorageProvider.allCases.filter { provider in
            targets.contains { $0.provider == provider && $0.exists }
        }
    }

    func targets(for provider: AIStorageProvider) -> [AIStorageTarget] {
        targets.filter { $0.provider == provider }
    }

    static let empty = AIStorageSnapshot(targets: [], scannedAt: .distantPast)
}

/// One file that matched a retained-text search. Deliberately carries a count
/// and nothing else: echoing the matched line would write the user's secret to
/// yet another surface.
struct AIStorageSearchHit: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let displayPath: String
    let provider: AIStorageProvider
    let matchCount: Int
}

/// What a purge actually did.
struct AIStoragePurgeResult {
    let freedBytes: UInt64
    let removedTargets: [String]
    let failures: [String]
}

#if DEBUG
extension AIStorageSnapshot {
    /// Fixture matching the shape of a real Mac Studio scan, for previews.
    static let preview = AIStorageSnapshot(targets: [
        AIStorageTarget(id: "lmstudio.server-logs", provider: .lmStudio, label: "Server logs",
                        path: "/x", displayPath: "~/.lmstudio/server-logs",
                        contents: "Prompts and responses, verbatim.", note: "prompts, no TTL",
                        noteIsWarning: true, isTextSearchable: true, exists: true,
                        sizeBytes: 31_150_000_000, fileCount: 3_140, capBytes: nil,
                        requiresOMLXStopped: false),
        AIStorageTarget(id: "lmstudio.conversations", provider: .lmStudio, label: "Conversations",
                        path: "/x", displayPath: "~/.lmstudio/conversations",
                        contents: "GUI chat history, full text.", note: nil,
                        noteIsWarning: false, isTextSearchable: true, exists: true,
                        sizeBytes: 528_000, fileCount: 42, capBytes: nil,
                        requiresOMLXStopped: false),
        AIStorageTarget(id: "omlx.cache", provider: .omlx, label: "Prompt KV cache",
                        path: "/x", displayPath: "~/.omlx/cache",
                        contents: "KV tensors derived from prompts.", note: "cap 150GB",
                        noteIsWarning: false, isTextSearchable: false, exists: true,
                        sizeBytes: 160_900_000_000, fileCount: 91_000,
                        capBytes: 161_061_273_600, requiresOMLXStopped: true),
        AIStorageTarget(id: "omlx.logs", provider: .omlx, label: "Logs",
                        path: "/x", displayPath: "~/.omlx/logs",
                        contents: "Metadata only.", note: "7-day retention",
                        noteIsWarning: false, isTextSearchable: true, exists: true,
                        sizeBytes: 1_940_000, fileCount: 7, capBytes: nil,
                        requiresOMLXStopped: false),
    ], scannedAt: Date().addingTimeInterval(-180))
}
#endif
