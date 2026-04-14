import Foundation
import Combine

enum DisplayMode: String, CaseIterable {
    case actual = "Actual"
    case capacity = "% Capacity"
}

enum TimeRange: String, CaseIterable {
    case oneMinute = "1m"
    case threeMinutes = "3m"
    case fiveMinutes = "5m"
    case tenMinutes = "10m"
    case fifteenMinutes = "15m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"

    var seconds: TimeInterval {
        switch self {
        case .oneMinute:      return 60
        case .threeMinutes:   return 180
        case .fiveMinutes:    return 300
        case .tenMinutes:     return 600
        case .fifteenMinutes: return 900
        case .thirtyMinutes:  return 1800
        case .oneHour:        return 3600
        }
    }
}

@MainActor
class MetricsManager: ObservableObject {
    @Published var currentSnapshot: SystemSnapshot?
    @Published var history = MetricsHistory(maxEntries: 1800) // 1 hour at 2s intervals
    @Published var isRunning = false
    @Published var displayMode: DisplayMode = .capacity
    @Published var timeRange: TimeRange = .fiveMinutes

    private var timer: Timer?
    var refreshInterval: TimeInterval = 2.0

    private let cpuCollector = CPUCollector()
    private let memoryCollector = MemoryCollector()
    private let gpuCollector = GPUCollector()
    private let diskCollector = DiskCollector()
    private let networkCollector = NetworkCollector()
    private let thermalCollector = ThermalCollector()
    private let selfCollector = SelfMetricsCollector()
    private let processCollector = ProcessCollector()
    private let lmStudioCollector = LMStudioCollector()

    init() {
        start()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { await collectMetrics() }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.collectMetrics()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func updateRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = interval
        if isRunning {
            stop()
            start()
        }
    }

    private func collectMetrics() async {
        // Fire LM Studio request concurrently with synchronous collectors
        async let lmStudioResult = lmStudioCollector.collect()

        let cpu = cpuCollector.collect()
        let memory = memoryCollector.collect()
        let gpu = gpuCollector.collect()
        let disk = diskCollector.collect()
        let network = networkCollector.collect()
        let thermal = thermalCollector.collect()
        let selfMetrics = selfCollector.collect()
        let processes = processCollector.collect()
        let lmStudio = await lmStudioResult

        let snapshot = SystemSnapshot(
            timestamp: Date(),
            cpu: cpu,
            memory: memory,
            gpu: gpu,
            disk: disk,
            network: network,
            thermal: thermal,
            selfMetrics: selfMetrics,
            processes: processes,
            lmStudio: lmStudio
        )
        currentSnapshot = snapshot
        history.append(snapshot)
    }
}
