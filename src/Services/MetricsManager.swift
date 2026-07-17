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

    /// All collection runs on this actor's background executor, off the main
    /// thread. See `CollectionEngine` for the isolation model.
    private let engine = CollectionEngine()

    /// Guards against a new pass starting before the previous one finishes if a
    /// collection tick runs longer than `refreshInterval`. MainActor-isolated,
    /// so the check/set is race-free.
    private var isCollecting = false

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
        // Skip this tick if the previous pass is still running so passes never
        // overlap or reenter (preserves the 2s cadence without pile-up).
        guard !isCollecting else { return }
        isCollecting = true
        defer { isCollecting = false }

        // Runs off-main on the engine actor; only the snapshot marshals back to
        // the main actor for the @Published assignment below.
        let snapshot = await engine.collect()
        currentSnapshot = snapshot
        history.append(snapshot)
    }
}
