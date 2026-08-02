import Foundation

/// Owns every collector and runs a full collection pass off the main actor.
///
/// Isolation model (QA #1): all stateful collectors are `actor`-isolated
/// properties here, so their cross-sample `previous*` delta state is only ever
/// touched from this actor's (non-main) executor. Because the collectors are
/// non-`Sendable` `final class`es stored as private `let`s, the compiler
/// guarantees they never escape the actor — there is no way for two threads to
/// touch a collector's `previous*` fields concurrently. `MetricsManager`
/// (`@MainActor`) drives one pass at a time via `await collect()` and never
/// reaches into a collector directly.
///
/// `LMStudioCollector` is itself an `actor` (M4/QA #9); we `await` it here, so
/// its `latest` write stays isolated to its own executor.
actor CollectionEngine {
    private let cpuCollector = CPUCollector()
    private let memoryCollector = MemoryCollector()
    private let gpuCollector = GPUCollector()
    private let diskCollector = DiskCollector()
    private let networkCollector = NetworkCollector()
    private let thermalCollector = ThermalCollector()
    private let powerCollector = PowerCollector()
    private let selfCollector = SelfMetricsCollector()
    private let processCollector = ProcessCollector()
    private let lmStudioCollector = LMStudioCollector()
    private let omlxCollector = OMLXCollector()
    private let ollamaCollector = OllamaCollector()

    /// Runs one full collection pass on the actor's executor (a cooperative
    /// background thread, never main) and returns an assembled snapshot. The
    /// `IOReportBridge` 100ms `Thread.sleep` inside the GPU/Power collectors
    /// therefore blocks a background pool thread, not the UI thread.
    func collect() async -> SystemSnapshot {
        // Fire the AI-backend HTTP polls concurrently with each other and with
        // the synchronous collectors. Each backend is independently offline-safe,
        // so a missing server costs one refused connection, not a stalled tick.
        async let lmStudioResult = lmStudioCollector.collect()
        async let omlxResult = omlxCollector.collect()
        async let ollamaResult = ollamaCollector.collect()

        let cpu = cpuCollector.collect()
        let memory = memoryCollector.collect()
        let gpu = gpuCollector.collect()
        let disk = diskCollector.collect()
        let network = networkCollector.collect()
        let thermal = thermalCollector.collect()
        let power = powerCollector.collect()
        let selfMetrics = selfCollector.collect()
        let processes = processCollector.collect()
        let lmStudio = await lmStudioResult
        let omlx = await omlxResult
        let ollama = await ollamaResult

        return SystemSnapshot(
            timestamp: Date(),
            cpu: cpu,
            memory: memory,
            gpu: gpu,
            disk: disk,
            network: network,
            thermal: thermal,
            power: power,
            selfMetrics: selfMetrics,
            processes: processes,
            lmStudio: lmStudio,
            omlx: omlx,
            ollama: ollama
        )
    }
}
