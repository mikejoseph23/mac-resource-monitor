import Foundation

class MetricsHistory: ObservableObject {
    @Published var snapshots: [SystemSnapshot] = []

    let maxEntries: Int

    init(maxEntries: Int = 300) {
        self.maxEntries = maxEntries
    }

    func append(_ snapshot: SystemSnapshot) {
        snapshots.append(snapshot)
        if snapshots.count > maxEntries {
            snapshots.removeFirst(snapshots.count - maxEntries)
        }
    }

    /// Returns snapshots within the given time range from now.
    func snapshots(in range: TimeRange) -> [SystemSnapshot] {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        return snapshots.filter { $0.timestamp >= cutoff }
    }

    func cpuHistory(range: TimeRange) -> [(Date, Double)] {
        snapshots(in: range).map { ($0.timestamp, $0.cpu.totalUsage) }
    }

    func memoryHistory(range: TimeRange) -> [(Date, Double)] {
        snapshots(in: range).map { ($0.timestamp, $0.memory.usagePercent) }
    }

    func gpuHistory(range: TimeRange) -> [(Date, Double)] {
        snapshots(in: range).map { ($0.timestamp, $0.gpu.utilizationPercent) }
    }

    func diskReadHistory(range: TimeRange) -> [(Date, Double)] {
        snapshots(in: range).map { ($0.timestamp, $0.disk.readBytesPerSec) }
    }

    func diskWriteHistory(range: TimeRange) -> [(Date, Double)] {
        snapshots(in: range).map { ($0.timestamp, $0.disk.writeBytesPerSec) }
    }

    func networkInHistory(range: TimeRange) -> [(Date, Double)] {
        snapshots(in: range).map { ($0.timestamp, $0.network.bytesInPerSec) }
    }

    func networkOutHistory(range: TimeRange) -> [(Date, Double)] {
        snapshots(in: range).map { ($0.timestamp, $0.network.bytesOutPerSec) }
    }

    func cpuPowerHistory(range: TimeRange) -> [(Date, Double)] {
        snapshots(in: range).compactMap { snap in
            snap.power.map { ($0.timestamp, $0.cpuPowerWatts) }
        }
    }

    func gpuPowerHistory(range: TimeRange) -> [(Date, Double)] {
        snapshots(in: range).compactMap { snap in
            snap.power.map { ($0.timestamp, $0.gpuPowerWatts) }
        }
    }

    func totalPowerHistory(range: TimeRange) -> [(Date, Double)] {
        snapshots(in: range).compactMap { snap in
            snap.power.map { ($0.timestamp, $0.totalPowerWatts) }
        }
    }

    func pcpuFrequencyHistory(range: TimeRange) -> [(Date, Double)] {
        snapshots(in: range).compactMap { snap in
            snap.power.map { ($0.timestamp, Double($0.pcpuFreqMHz) / 1000.0) }
        }
    }
}
