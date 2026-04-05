import SwiftUI

enum DashboardTab: String, CaseIterable {
    case dashboard = "Dashboard"
    case processes = "Processes"
}

struct DashboardView: View {
    @EnvironmentObject private var metricsManager: MetricsManager
    @State private var selectedTab: DashboardTab = .dashboard

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar
            headerBar

            Divider()

            // Tab content
            switch selectedTab {
            case .dashboard:
                ScrollView {
                    VStack(spacing: 16) {
                        LazyVGrid(columns: columns, spacing: 14) {
                            cpuCard
                            memoryCard
                            gpuCard
                            diskCard
                            networkCard
                            thermalCard
                        }

                        aiBackendsSection
                    }
                    .padding(16)
                }

            case .processes:
                if let snapshot = metricsManager.currentSnapshot {
                    ProcessListView(processes: snapshot.processes)
                } else {
                    Spacer()
                    Text("Waiting for data...")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            Divider()

            // Footer: self metrics
            SelfMetricsView(selfMetrics: metricsManager.currentSnapshot?.selfMetrics)
        }
        .frame(minWidth: 860, minHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var isActual: Bool {
        metricsManager.displayMode == .actual
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Image(systemName: "gauge.open.with.lines.needle.33percent.badge.arrow.down")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            Text("MacResourceMonitor")
                .font(.system(size: 14, weight: .semibold))

            Spacer().frame(width: 16)

            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(DashboardTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            Spacer()

            // Display mode toggle (only on dashboard tab)
            if selectedTab == .dashboard {
                Picker("", selection: $metricsManager.displayMode) {
                    ForEach(DisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                Spacer().frame(width: 12)
            }

            // Running indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(metricsManager.isRunning ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text(metricsManager.isRunning ? "Live" : "Paused")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Cards

    private var cpuCard: some View {
        let snapshot = metricsManager.currentSnapshot
        let cpu = snapshot?.cpu
        let usage = cpu?.totalUsage ?? 0
        let coreCount = cpu?.coreCount ?? 0
        let activeCores = usage / 100.0 * Double(coreCount)
        return MetricCardView(
            title: "CPU",
            icon: "cpu",
            value: isActual
                ? String(format: "%.1f cores", activeCores)
                : String(format: "%.1f%%", usage),
            subtitle: isActual
                ? String(format: "%.1f%% of %d cores", usage, coreCount)
                : "\(coreCount) cores",
            severity: .from(percent: usage),
            sparklineData: metricsManager.history.cpuHistory,
            sparklineFixedRange: isActual ? nil : (min: 0, max: 100),
            details: [
                ("System", String(format: "%.1f%%", cpu?.systemUsage ?? 0)),
                ("User", String(format: "%.1f%%", cpu?.userUsage ?? 0)),
                ("Idle", String(format: "%.1f%%", cpu?.idleUsage ?? 0)),
                ("Threads", formatCount(cpu?.threadCount ?? 0)),
                ("Processes", formatCount(cpu?.processCount ?? 0)),
            ]
        )
    }

    private var memoryCard: some View {
        let snapshot = metricsManager.currentSnapshot
        let mem = snapshot?.memory
        let usage = mem?.usagePercent ?? 0
        let totalGB = Double(mem?.totalBytes ?? 0) / (1024 * 1024 * 1024)
        let usedGB = Double(mem?.usedBytes ?? 0) / (1024 * 1024 * 1024)
        return MetricCardView(
            title: "Memory",
            icon: "memorychip",
            value: isActual
                ? String(format: "%.1f GB", usedGB)
                : String(format: "%.0f%%", usage),
            subtitle: isActual
                ? String(format: "%.0f%% of %.0f GB", usage, totalGB)
                : String(format: "%.1f / %.0f GB", usedGB, totalGB),
            severity: .from(percent: usage),
            sparklineData: isActual
                ? metricsManager.history.memoryHistory.map { ($0.0, $0.1 / 100.0 * totalGB) }
                : metricsManager.history.memoryHistory,
            sparklineFixedRange: isActual ? nil : (min: 0, max: 100),
            details: [
                ("Physical", formatGBorMB(mem?.totalBytes ?? 0)),
                ("App Memory", formatGBorMB(mem?.appMemoryBytes ?? 0)),
                ("Wired", formatGBorMB(mem?.wiredBytes ?? 0)),
                ("Compressed", formatGBorMB(mem?.compressedBytes ?? 0)),
                ("Cached", formatGBorMB(mem?.cachedBytes ?? 0)),
                ("Swap Used", formatGBorMB(mem?.swapUsedBytes ?? 0)),
            ]
        )
    }

    private var gpuCard: some View {
        let snapshot = metricsManager.currentSnapshot
        let usage = snapshot?.gpu.utilizationPercent ?? 0
        let coreCount = snapshot?.gpu.coreCount ?? 0
        let activeCores = usage / 100.0 * Double(coreCount)
        return MetricCardView(
            title: "GPU",
            icon: "rectangle.3.group",
            value: isActual
                ? String(format: "%.0f cores", activeCores)
                : String(format: "%.0f%%", usage),
            subtitle: isActual
                ? String(format: "%.0f%% of %d cores", usage, coreCount)
                : "\(coreCount) cores",
            severity: .from(percent: usage),
            sparklineData: metricsManager.history.gpuHistory,
            sparklineFixedRange: isActual ? nil : (min: 0, max: 100),
            details: [
                ("Utilization", String(format: "%.1f%%", usage)),
                ("Active Cores", String(format: "%.0f / %d", activeCores, coreCount)),
                ("Chip", "M3 Ultra"),
                ("Total Cores", "\(coreCount)"),
                ("Neural Engine", "32 cores"),
            ]
        )
    }

    private var diskCard: some View {
        let snapshot = metricsManager.currentSnapshot
        let disk = snapshot?.disk
        let readRate = disk?.readBytesPerSec ?? 0
        let writeRate = disk?.writeBytesPerSec ?? 0
        let combinedRate = readRate + writeRate
        let totalBytes = Double(disk?.totalDiskSpace ?? 0)
        let usedBytes = Double(disk?.usedDiskSpace ?? 0)
        let usagePercent = totalBytes > 0 ? (usedBytes / totalBytes) * 100 : 0
        let spaceStr = formatDiskSpace(used: usedBytes, total: totalBytes)
        return MetricCardView(
            title: "Disk",
            icon: "internaldrive",
            value: isActual
                ? formatIORate(combinedRate)
                : String(format: "%.0f%%", usagePercent),
            subtitle: isActual
                ? spaceStr
                : String(format: "R: %@  W: %@", formatIORate(readRate), formatIORate(writeRate)),
            severity: isActual ? .normal : .from(percent: usagePercent, warningAt: 80, criticalAt: 95),
            sparklineData: metricsManager.history.diskReadHistory,
            details: [
                ("Read/sec", formatIORate(readRate)),
                ("Write/sec", formatIORate(writeRate)),
                ("Read Ops/sec", String(format: "%.0f", disk?.readOpsPerSec ?? 0)),
                ("Write Ops/sec", String(format: "%.0f", disk?.writeOpsPerSec ?? 0)),
                ("Total Read", formatGBorMB(disk?.totalReadBytes ?? 0)),
                ("Total Written", formatGBorMB(disk?.totalWriteBytes ?? 0)),
            ]
        )
    }

    private var networkCard: some View {
        let snapshot = metricsManager.currentSnapshot
        let net = snapshot?.network
        let inBytes = net?.bytesInPerSec ?? 0
        let outBytes = net?.bytesOutPerSec ?? 0
        return MetricCardView(
            title: "Network",
            icon: "network",
            value: isActual
                ? formatNetworkRate(inBytes)
                : formatNetworkRate(inBytes + outBytes),
            subtitle: isActual
                ? String(format: "Up: %@", formatNetworkRate(outBytes))
                : String(format: "In: %@  Out: %@", formatNetworkRate(inBytes), formatNetworkRate(outBytes)),
            severity: .normal,
            sparklineData: metricsManager.history.networkInHistory,
            details: [
                ("Down/sec", formatNetworkRate(inBytes)),
                ("Up/sec", formatNetworkRate(outBytes)),
                ("Packets In/sec", String(format: "%.0f", net?.packetsInPerSec ?? 0)),
                ("Packets Out/sec", String(format: "%.0f", net?.packetsOutPerSec ?? 0)),
                ("Data Received", formatGBorMB(net?.totalBytesIn ?? 0)),
                ("Data Sent", formatGBorMB(net?.totalBytesOut ?? 0)),
            ]
        )
    }

    private var thermalCard: some View {
        let snapshot = metricsManager.currentSnapshot
        let state = snapshot?.thermal.thermalState ?? .nominal
        let isThrottled = snapshot?.thermal.isThrottled ?? false
        let cpuUsage = snapshot?.cpu.totalUsage ?? 0
        let gpuUsage = snapshot?.gpu.utilizationPercent ?? 0
        let (label, severity) = thermalDisplay(state: state, throttled: isThrottled)
        return MetricCardView(
            title: "Thermal",
            icon: "thermometer.medium",
            value: label,
            subtitle: isThrottled ? "Throttled" : "Not throttled",
            severity: severity,
            sparklineData: metricsManager.history.gpuHistory,
            details: [
                ("State", label),
                ("Throttled", isThrottled ? "Yes" : "No"),
                ("CPU Load", String(format: "%.1f%%", cpuUsage)),
                ("GPU Load", String(format: "%.1f%%", gpuUsage)),
                ("Pressure", snapshot?.memory.pressureLevel.rawValue ?? "N/A"),
            ]
        )
    }

    // MARK: - AI Backends

    private var aiBackendsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "brain")
                    .foregroundStyle(.secondary)
                Text("Local AI Models")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("No backends detected")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            VStack(spacing: 12) {
                aiBackendRow(
                    name: "LM Studio",
                    icon: "server.rack",
                    status: .notRunning
                )
                aiBackendRow(
                    name: "Ollama",
                    icon: "terminal",
                    status: .notRunning
                )
            }
            .padding(14)
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        }
    }

    private func aiBackendRow(name: String, icon: String, status: AIBackendStatus) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(status.color)
                .frame(width: 20)

            Text(name)
                .font(.system(size: 12, weight: .medium))

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
                Text(status.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private func formatGBorMB(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024)
        }
        if mb >= 1 {
            return String(format: "%.0f MB", mb)
        }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    private func formatCount(_ value: Int) -> String {
        if value >= 1000 {
            return String(format: "%d,%03d", value / 1000, value % 1000)
        }
        return "\(value)"
    }

    private func formatDiskSpace(used: Double, total: Double) -> String {
        let totalTB = total / (1024 * 1024 * 1024 * 1024)
        let usedTB = used / (1024 * 1024 * 1024 * 1024)
        if totalTB >= 1.0 {
            return String(format: "%.1f / %.1f TB used", usedTB, totalTB)
        }
        let totalGB = total / (1024 * 1024 * 1024)
        let usedGB = used / (1024 * 1024 * 1024)
        return String(format: "%.0f / %.0f GB used", usedGB, totalGB)
    }

    private func formatIORate(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSec / (1024 * 1024))
        }
        return String(format: "%.0f KB/s", bytesPerSec / 1024)
    }

    private func formatNetworkRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSec / (1024 * 1024))
        }
        return String(format: "%.0f KB/s", bytesPerSec / 1024)
    }

    private func thermalDisplay(state: ProcessInfo.ThermalState, throttled: Bool) -> (String, MetricSeverity) {
        switch state {
        case .nominal:
            return ("Nominal", .normal)
        case .fair:
            return ("Fair", .normal)
        case .serious:
            return ("Serious", .warning)
        case .critical:
            return ("Critical", .critical)
        @unknown default:
            return ("Unknown", .normal)
        }
    }
}

// MARK: - AI Backend Status

enum AIBackendStatus {
    case notRunning
    case connected
    case inferring

    var label: String {
        switch self {
        case .notRunning: return "Not Running"
        case .connected: return "Connected"
        case .inferring: return "Inferring"
        }
    }

    var color: Color {
        switch self {
        case .notRunning: return .gray
        case .connected: return .green
        case .inferring: return .orange
        }
    }
}

#Preview {
    DashboardView()
        .environmentObject(MetricsManager())
        .frame(width: 900, height: 700)
}
