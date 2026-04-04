import Foundation

final class ThermalCollector {

    func collect() -> ThermalMetrics {
        let timestamp = Date()
        let state = ProcessInfo.processInfo.thermalState

        return ThermalMetrics(
            timestamp: timestamp,
            thermalState: state,
            isThrottled: state == .serious || state == .critical
        )
    }
}
