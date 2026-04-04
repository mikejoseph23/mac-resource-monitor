import Foundation
import Combine

enum DisplayMode: String, CaseIterable {
    case actual = "Actual"
    case capacity = "% Capacity"
}

@MainActor
class MetricsManager: ObservableObject {
    @Published var currentSnapshot: SystemSnapshot?
    @Published var history = MetricsHistory()
    @Published var isRunning = false
    @Published var displayMode: DisplayMode = .actual

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

    init() {
        start()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        collectMetrics()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.collectMetrics()
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

    private func collectMetrics() {
        let snapshot = SystemSnapshot(
            timestamp: Date(),
            cpu: cpuCollector.collect(),
            memory: memoryCollector.collect(),
            gpu: gpuCollector.collect(),
            disk: diskCollector.collect(),
            network: networkCollector.collect(),
            thermal: thermalCollector.collect(),
            selfMetrics: selfCollector.collect(),
            processes: processCollector.collect()
        )
        currentSnapshot = snapshot
        history.append(snapshot)
    }
}
