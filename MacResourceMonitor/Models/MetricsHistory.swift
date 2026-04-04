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

    var cpuHistory: [(Date, Double)] {
        snapshots.map { ($0.timestamp, $0.cpu.totalUsage) }
    }

    var memoryHistory: [(Date, Double)] {
        snapshots.map { ($0.timestamp, $0.memory.usagePercent) }
    }

    var gpuHistory: [(Date, Double)] {
        snapshots.map { ($0.timestamp, $0.gpu.utilizationPercent) }
    }

    var diskReadHistory: [(Date, Double)] {
        snapshots.map { ($0.timestamp, $0.disk.readBytesPerSec) }
    }

    var diskWriteHistory: [(Date, Double)] {
        snapshots.map { ($0.timestamp, $0.disk.writeBytesPerSec) }
    }

    var networkInHistory: [(Date, Double)] {
        snapshots.map { ($0.timestamp, $0.network.bytesInPerSec) }
    }

    var networkOutHistory: [(Date, Double)] {
        snapshots.map { ($0.timestamp, $0.network.bytesOutPerSec) }
    }
}
