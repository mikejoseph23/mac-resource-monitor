import Foundation
import Combine

enum DashboardWidget: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, disk, diskIO, network, thermal, power, frequency
    case volumes, lmStudio, aiStorage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cpu:        return "CPU"
        case .memory:     return "Memory"
        case .gpu:        return "GPU"
        case .disk:       return "Disk"
        case .diskIO:     return "Disk I/O"
        case .network:    return "Network"
        case .thermal:    return "Thermal"
        case .power:      return "Power"
        case .frequency:  return "Frequency"
        case .volumes:    return "Storage Volumes"
        case .lmStudio:   return "Local AI Models"
        case .aiStorage:  return "Local AI Storage"
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

enum DashboardProfile: String, CaseIterable, Identifiable {
    case `default` = "Default"
    case localInference = "Local Inference"

    var id: String { rawValue }

    var displayName: String { rawValue }

    /// Cards in the metrics grid, in render order. Anything omitted still
    /// renders if visible — appended at the end — so a new widget shows up
    /// even if a profile predates it.
    var gridOrder: [DashboardWidget] {
        switch self {
        case .default:
            return [.cpu, .memory, .gpu, .disk, .diskIO, .network, .thermal, .power, .frequency]
        case .localInference:
            // Inference-critical first: RAM/swap, GPU utilization, power draw
            // and clocks (so you can see if the chip is actually working),
            // thermal (throttling kills tok/s). CPU still matters for
            // tokenization + helpers. Disk for model loads. Network last.
            return [.memory, .gpu, .power, .frequency, .thermal, .cpu, .disk, .diskIO, .network]
        }
    }

    /// Case-insensitive substring matches against process / group names.
    /// `nil` means "no filter — show everything".
    var processNameFilter: [String]? {
        switch self {
        case .default:
            return nil
        case .localInference:
            return ["ollama", "llama", "lm studio", "lmstudio", "mlx", "omlx",
                    "vllm", "python", "huggingface", "text-generation"]
        }
    }

    /// Widgets rendered double-wide (span 2 of 3 grid columns) with a
    /// featured visual treatment. Default keeps everything uniform.
    var emphasized: Set<DashboardWidget> {
        switch self {
        case .default:
            return []
        case .localInference:
            return [.memory, .gpu, .power]
        }
    }
}

@MainActor
final class DashboardLayout: ObservableObject {
    @Published private(set) var hidden: Set<DashboardWidget>
    @Published var activeProfile: DashboardProfile {
        didSet { persistProfile() }
    }

    private let hiddenKey = "dashboard.hiddenWidgets"
    private let profileKey = "dashboard.activeProfile"

    init() {
        let raw = UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []
        self.hidden = Set(raw.compactMap(DashboardWidget.init(rawValue:)))
        let storedProfile = UserDefaults.standard.string(forKey: profileKey)
            .flatMap(DashboardProfile.init(rawValue:)) ?? .default
        self.activeProfile = storedProfile
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
        persistHidden()
    }

    /// Widgets for the metrics grid in the active profile's order. Any
    /// widget the profile forgot is appended so nothing silently disappears.
    func orderedGridWidgets() -> [DashboardWidget] {
        let gridWidgets: [DashboardWidget] = [.cpu, .memory, .gpu, .disk, .diskIO,
                                              .network, .thermal, .power, .frequency]
        let ordered = activeProfile.gridOrder.filter { gridWidgets.contains($0) }
        let missing = gridWidgets.filter { !ordered.contains($0) }
        return ordered + missing
    }

    private func persistHidden() {
        UserDefaults.standard.set(hidden.map(\.rawValue), forKey: hiddenKey)
    }

    private func persistProfile() {
        UserDefaults.standard.set(activeProfile.rawValue, forKey: profileKey)
    }
}
