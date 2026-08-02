import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var metricsManager: MetricsManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .foregroundStyle(.secondary)
                Text("Resource Monitor")
                    .font(.headline)
                Spacer()
                if metricsManager.isRunning {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }
            }

            Divider()

            if let snapshot = metricsManager.currentSnapshot {
                // CPU
                MetricRow(
                    icon: "cpu",
                    label: "CPU",
                    value: snapshot.cpu.totalUsage,
                    color: colorForUsage(snapshot.cpu.totalUsage)
                )

                // Memory
                MetricRow(
                    icon: "memorychip",
                    label: "Memory",
                    value: snapshot.memory.usagePercent,
                    color: colorForUsage(snapshot.memory.usagePercent),
                    detail: formatBytes(snapshot.memory.usedBytes) + " / " + formatBytes(snapshot.memory.totalBytes)
                )

                // GPU
                MetricRow(
                    icon: "rectangle.3.group",
                    label: "GPU",
                    value: snapshot.gpu.utilizationPercent,
                    color: colorForUsage(snapshot.gpu.utilizationPercent)
                )

                Divider()

                // Thermal state
                HStack(spacing: 6) {
                    Image(systemName: thermalIcon(for: snapshot.thermal.thermalState))
                        .foregroundStyle(thermalColor(for: snapshot.thermal.thermalState))
                    Text("Thermal")
                        .font(.subheadline)
                    Spacer()
                    Text(thermalLabel(for: snapshot.thermal.thermalState))
                        .font(.subheadline)
                        .foregroundStyle(thermalColor(for: snapshot.thermal.thermalState))
                }

                // AI backend status — only the ones that are actually up, so
                // the popover doesn't grow three dead rows on a machine that
                // runs none of them.
                let backends = runningBackends(snapshot)
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .foregroundStyle(.secondary)
                    Text("Local AI")
                        .font(.subheadline)
                    Spacer()
                    Text(backends.isEmpty ? "Not Running" : backends.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(backends.isEmpty ? Color.secondary : Color.green)
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Collecting metrics...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 8)
            }

            Divider()

            // Open Dashboard button
            Button {
                dismiss()
                if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
                    window.makeKeyAndOrderFront(nil)
                }
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                HStack {
                    Image(systemName: "macwindow")
                    Text("Open Dashboard")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(16)
        .frame(width: 300)
    }

    // MARK: - Helpers

    private func colorForUsage(_ percent: Double) -> Color {
        // Unified with the dashboard: MetricSeverity owns the thresholds
        // (70 / 90) and the green / orange / red palette.
        MetricSeverity.utilization(percent).color
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.1f GB", gb)
    }

    /// Names of the local inference servers currently answering, with a loaded
    /// model count where the backend reports one.
    private func runningBackends(_ snapshot: SystemSnapshot) -> [String] {
        var names: [String] = []
        if snapshot.lmStudio.status == .connected {
            names.append("LM Studio (\(snapshot.lmStudio.loadedCount))")
        }
        if snapshot.omlx.isOnline {
            names.append("oMLX (\(snapshot.omlx.loadedCount))")
        }
        if snapshot.ollama.isOnline {
            names.append("Ollama (\(snapshot.ollama.loadedCount))")
        }
        return names
    }

    private func thermalIcon(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "thermometer.low"
        case .fair: return "thermometer.medium"
        case .serious: return "thermometer.high"
        case .critical: return "thermometer.sun.fill"
        @unknown default: return "thermometer.medium"
        }
    }

    private func thermalLabel(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Normal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private func thermalColor(for state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }
}

// MARK: - Metric Row

private struct MetricRow: View {
    let icon: String
    let label: String
    let value: Double
    let color: Color
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .frame(width: 16, alignment: .center)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.0f%%", value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(color)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geometry.size.width * min(max(value / 100.0, 0), 1), height: 4)
                }
            }
            .frame(height: 4)

            if let detail {
                HStack {
                    Spacer()
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

#Preview {
    MenuBarView()
        .environmentObject(MetricsManager())
}
