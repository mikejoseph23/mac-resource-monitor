import Foundation
import CoreFoundation

// Sample loop and channel-matching adapted from vladkens/macmon (MIT).

final class PowerCollector {

    private let bridge: IOReportBridge?
    private let soc: SoCInfo?

    init() {
        guard Architecture.isAppleSilicon else {
            self.bridge = nil
            self.soc = nil
            return
        }
        self.soc = SoCInfo.read()
        self.bridge = IOReportBridge(channels: [
            ("Energy Model", nil),                              // CPU/GPU/ANE power
            ("CPU Stats",   "CPU Core Performance States"),     // per-cluster freq residency
            ("GPU Stats",   "GPU Performance States"),          // GPU freq residency
        ])
    }

    // 100 ms window: long enough to give Energy Model channels a stable
    // reading (~10 mJ at 0.1 W idle), short enough to keep the 2 s collect
    // tick fluid. macmon defaults to 1000 ms in their TUI; we don't have
    // that luxury since the rest of the dashboard is also waiting.
    private let sampleWindowMs: UInt32 = 100

    /// Returns nil on Intel or when IOReport is otherwise unavailable.
    /// Blocks the calling thread for ~`sampleWindowMs` while sampling.
    func collect() -> PowerMetrics? {
        guard let bridge, let soc else { return nil }
        guard let (items, elapsedMs) = bridge.sampleDelta(windowMs: sampleWindowMs) else { return nil }

        var cpuW = 0.0
        var gpuW = 0.0
        var aneW = 0.0
        var ecpuFreqs: [(UInt32, Double)] = []      // (avgMHz, activeRatio)
        var pcpuFreqs: [(UInt32, Double)] = []
        var gpuFreq: (UInt32, Double) = (0, 0)

        for it in items {
            switch it.group {
            case "Energy Model":
                guard let w = IOReportBridge.watts(item: it, elapsedMs: elapsedMs) else { continue }
                let ch = it.channel
                if ch == "GPU Energy" {
                    gpuW += w
                } else if ch.hasSuffix("CPU Energy") {       // "CPU Energy" or "DIE_N_CPU Energy" on Ultra
                    cpuW += w
                } else if ch.hasPrefix("ANE") {              // "ANE", "ANE0", "ANE0_N"
                    aneW += w
                }

            case "CPU Stats":
                guard it.subgroup == "CPU Core Performance States" else { continue }
                let ch = it.channel
                // Ultra chips prefix channels with "DIE_N_"; M5 renames ECPU→MCPU.
                if ch.contains("PCPU") {
                    pcpuFreqs.append(weightedFreq(states: it.states, table: soc.pcpuFreqsMHz))
                } else if ch.contains("ECPU") || ch.contains("MCPU") {
                    ecpuFreqs.append(weightedFreq(states: it.states, table: soc.ecpuFreqsMHz))
                }

            case "GPU Stats":
                guard it.subgroup == "GPU Performance States",
                      it.channel == "GPUPH" else { continue }
                // GPU table's first entry is an "off" floor; skip it.
                let table = soc.gpuFreqsMHz.count > 1 ? Array(soc.gpuFreqsMHz.dropFirst()) : soc.gpuFreqsMHz
                gpuFreq = weightedFreq(states: it.states, table: table)

            default: break
            }
        }

        // Average across cluster cores. Filter all-idle cores (ratio == 0)
        // so a single hot core's freq isn't pulled toward the floor.
        let activeECPU = ecpuFreqs.filter { $0.1 > 0 }
        let avgECPU = avg(activeECPU.map { Double($0.0) })
        let avgPCPU = avg(pcpuFreqs.filter { $0.1 > 0 }.map { Double($0.0) })

        return PowerMetrics(
            timestamp: Date(),
            cpuPowerWatts: cpuW,
            gpuPowerWatts: gpuW,
            anePowerWatts: aneW,
            totalPowerWatts: cpuW + gpuW + aneW,
            ecpuFreqMHz: Int(avgECPU.rounded()),
            pcpuFreqMHz: Int(avgPCPU.rounded()),
            gpuFreqMHz: Int(Double(gpuFreq.0).rounded())
        )
    }

    // MARK: - Frequency residency math

    /// Compute time-weighted average frequency for a single core/cluster
    /// using the chip's DVFS frequency table.
    /// Returns (avgMHz, activeRatio) — activeRatio in [0, 1].
    private func weightedFreq(states: [(name: String, residency: Int64)], table: [UInt32]) -> (UInt32, Double) {
        guard !states.isEmpty, !table.isEmpty else { return (0, 0) }

        // The first one or two states are "IDLE", "DOWN", or "OFF" depending
        // on the chip; skip them so the active states line up 1:1 with the
        // frequency table.
        guard let firstActive = states.firstIndex(where: { name, _ in
            name != "IDLE" && name != "DOWN" && name != "OFF"
        }) else { return (0, 0) }

        let activeStates = states[firstActive...]
        let activeSum = activeStates.reduce(0.0) { $0 + Double($1.residency) }
        let total = states.reduce(0.0) { $0 + Double($1.residency) }
        guard activeSum > 0, total > 0 else { return (0, 0) }

        var avgMHz = 0.0
        for (i, freq) in table.enumerated() {
            guard firstActive + i < states.count else { break }
            let res = Double(states[firstActive + i].residency)
            avgMHz += (res / activeSum) * Double(freq)
        }
        return (UInt32(avgMHz.rounded()), activeSum / total)
    }

    private func avg(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
