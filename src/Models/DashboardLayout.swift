import Foundation
import Combine

enum DashboardWidget: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, disk, network, thermal, power, frequency
    case volumes, lmStudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cpu:        return "CPU"
        case .memory:     return "Memory"
        case .gpu:        return "GPU"
        case .disk:       return "Disk"
        case .network:    return "Network"
        case .thermal:    return "Thermal"
        case .power:      return "Power"
        case .frequency:  return "Frequency"
        case .volumes:    return "Storage Volumes"
        case .lmStudio:   return "Local AI Models"
        }
    }

    /// Widgets that have nothing to show on Intel Macs and shouldn't appear
    /// in the toggle list there.
    var requiresAppleSilicon: Bool {
        switch self {
        case .power, .frequency: return true
        default: return false
        }
    }
}

@MainActor
final class DashboardLayout: ObservableObject {
    @Published private(set) var hidden: Set<DashboardWidget>

    private let storageKey = "dashboard.hiddenWidgets"

    init() {
        let raw = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        self.hidden = Set(raw.compactMap(DashboardWidget.init(rawValue:)))
    }

    func isVisible(_ widget: DashboardWidget) -> Bool {
        !hidden.contains(widget)
    }

    func setVisible(_ widget: DashboardWidget, _ visible: Bool) {
        if visible {
            hidden.remove(widget)
        } else {
            hidden.insert(widget)
        }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(hidden.map(\.rawValue), forKey: storageKey)
    }
}
