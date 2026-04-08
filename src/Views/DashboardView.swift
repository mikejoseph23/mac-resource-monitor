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
                        // At-a-glance gauges
                        gaugeRow

                        LazyVGrid(columns: columns, spacing: 14) {
                            cpuCard
                            memoryCard
                            gpuCard
                            diskCard
                            networkCard
                            thermalCard
                        }

                        if let volumes = metricsManager.currentSnapshot?.disk.volumes, !volumes.isEmpty {
                            VolumesPanelView(volumes: volumes)
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

    private var selectedRange: TimeRange {
        metricsManager.timeRange
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

            // Display mode toggle and time range (only on dashboard tab)
            if selectedTab == .dashboard {
                Picker("", selection: $metricsManager.timeRange) {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 60)

                Spacer().frame(width: 8)

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

    // MARK: - Gauges

    private var gaugeRow: some View {
        HStack(spacing: 14) {
            cpuGauge
            memoryGauge
            diskSpaceGauge
        }
    }

    private var cpuGauge: some View {
        let snapshot = metricsManager.currentSnapshot
        let usage = snapshot?.cpu.totalUsage ?? 0
        let coreCount = snapshot?.cpu.coreCount ?? 0
        return GaugeMeterView(
            title: "CPU",
            icon: "cpu",
            percent: usage,
            subtitle: "\(coreCount) cores",
            severity: .from(percent: usage)
        )
    }

    private var memoryGauge: some View {
        let snapshot = metricsManager.currentSnapshot
        let mem = snapshot?.memory
        let usage = mem?.usagePercent ?? 0
        let totalGB = Double(mem?.totalBytes ?? 0) / (1024 * 1024 * 1024)
        let usedGB = Double(mem?.usedBytes ?? 0) / (1024 * 1024 * 1024)
        return GaugeMeterView(
            title: "Memory",
            icon: "memorychip",
            percent: usage,
            subtitle: String(format: "%.1f / %.0f GB", usedGB, totalGB),
            severity: .from(percent: usage)
        )
    }

    private var diskSpaceGauge: some View {
        let snapshot = metricsManager.currentSnapshot
        let disk = snapshot?.disk
        let totalBytes = Double(disk?.totalDiskSpace ?? 0)
        let usedBytes = Double(disk?.usedDiskSpace ?? 0)
        let usagePercent = totalBytes > 0 ? (usedBytes / totalBytes) * 100 : 0
        return GaugeMeterView(
            title: "Disk",
            icon: "internaldrive",
            percent: usagePercent,
            subtitle: formatDiskSpace(used: usedBytes, total: totalBytes),
            severity: .from(percent: usagePercent, warningAt: 80, criticalAt: 95)
        )
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
            sparklineData: metricsManager.history.cpuHistory(range: selectedRange),
            sparklineFixedRange: isActual ? nil : (min: 0, max: 100),
            sparklineValueFormatter: { String(format: "%.1f%%", $0) },
            details: [
                ("System", String(format: "%.2f%%", cpu?.systemUsage ?? 0), Color.red),
                ("User", String(format: "%.2f%%", cpu?.userUsage ?? 0), Color.cyan),
                ("Idle", String(format: "%.2f%%", cpu?.idleUsage ?? 0), nil),
                ("Threads", formatCount(cpu?.threadCount ?? 0), nil),
                ("Processes", formatCount(cpu?.processCount ?? 0), nil),
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
                ? metricsManager.history.memoryHistory(range: selectedRange).map { ($0.0, $0.1 / 100.0 * totalGB) }
                : metricsManager.history.memoryHistory(range: selectedRange),
            sparklineFixedRange: isActual ? nil : (min: 0, max: 100),
            sparklineValueFormatter: isActual
                ? { String(format: "%.1f GB", $0) }
                : { String(format: "%.1f%%", $0) },
            details: [
                ("Physical", formatGBorMB(mem?.totalBytes ?? 0), nil),
                ("App Memory", formatGBorMB(mem?.appMemoryBytes ?? 0), Color.cyan),
                ("Wired", formatGBorMB(mem?.wiredBytes ?? 0), Color.red),
                ("Compressed", formatGBorMB(mem?.compressedBytes ?? 0), Color.orange),
                ("Cached", formatGBorMB(mem?.cachedBytes ?? 0), nil),
                ("Swap Used", formatGBorMB(mem?.swapUsedBytes ?? 0), Color.yellow),
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
            sparklineData: metricsManager.history.gpuHistory(range: selectedRange),
            sparklineFixedRange: isActual ? nil : (min: 0, max: 100),
            sparklineValueFormatter: { String(format: "%.1f%%", $0) },
            details: [
                ("Utilization", String(format: "%.1f%%", usage), nil),
                ("Active Cores", String(format: "%.0f / %d", activeCores, coreCount), nil),
                ("Chip", "M3 Ultra", nil),
                ("Total Cores", "\(coreCount)", nil),
                ("Neural Engine", "32 cores", nil),
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
            sparklineData: metricsManager.history.diskReadHistory(range: selectedRange),
            sparklineValueFormatter: { v in
                if v >= 1_000_000 { return String(format: "%.1f MB/s", v / (1024 * 1024)) }
                return String(format: "%.0f KB/s", v / 1024)
            },
            details: [
                ("Read/sec", formatIORate(readRate), nil),
                ("Write/sec", formatIORate(writeRate), nil),
                ("Read Ops/sec", String(format: "%.0f", disk?.readOpsPerSec ?? 0), nil),
                ("Write Ops/sec", String(format: "%.0f", disk?.writeOpsPerSec ?? 0), nil),
                ("Total Read", formatGBorMB(disk?.totalReadBytes ?? 0), nil),
                ("Total Written", formatGBorMB(disk?.totalWriteBytes ?? 0), nil),
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
            sparklineData: metricsManager.history.networkInHistory(range: selectedRange),
            sparklineValueFormatter: { v in
                if v >= 1_000_000 { return String(format: "%.1f MB/s", v / (1024 * 1024)) }
                return String(format: "%.0f KB/s", v / 1024)
            },
            details: [
                ("Down/sec", formatNetworkRate(inBytes), nil),
                ("Up/sec", formatNetworkRate(outBytes), nil),
                ("Packets In/sec", String(format: "%.0f", net?.packetsInPerSec ?? 0), nil),
                ("Packets Out/sec", String(format: "%.0f", net?.packetsOutPerSec ?? 0), nil),
                ("Data Received", formatGBorMB(net?.totalBytesIn ?? 0), nil),
                ("Data Sent", formatGBorMB(net?.totalBytesOut ?? 0), nil),
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
            sparklineData: metricsManager.history.gpuHistory(range: selectedRange),
            sparklineValueFormatter: { String(format: "%.1f%%", $0) },
            details: [
                ("State", label, nil),
                ("Throttled", isThrottled ? "Yes" : "No", nil),
                ("CPU Load", String(format: "%.1f%%", cpuUsage), nil),
                ("GPU Load", String(format: "%.1f%%", gpuUsage), nil),
                ("Pressure", snapshot?.memory.pressureLevel.rawValue ?? "N/A", nil),
            ]
        )
    }

    // MARK: - AI Backends

    private var aiBackendsSection: some View {
        let lm = metricsManager.currentSnapshot?.lmStudio ?? .offline
        return VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "brain")
                    .foregroundStyle(.secondary)
                Text("Local AI Models")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                lmStudioStatusBadge(lm)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            switch lm.status {
            case .offline:
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 14))
                        .foregroundStyle(.gray)
                        .frame(width: 20)
                    Text("LM Studio")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(Color.gray).frame(width: 6, height: 6)
                        Text("Not Running")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)

            case .connected:
                VStack(spacing: 0) {
                    // Summary row
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 14))
                            .foregroundStyle(.green)
                            .frame(width: 20)
                        Text("LM Studio")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(lm.loadedCount) loaded / \(lm.availableCount) available")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    // Resource usage meters
                    if lm.processMemoryBytes > 0 || lm.processCPU > 0 {
                        Divider().opacity(0.3)
                        lmStudioResourceRow(lm)
                    }

                    // Loaded models
                    if !lm.loadedModels.isEmpty {
                        Divider().opacity(0.3)
                        VStack(spacing: 6) {
                            ForEach(lm.loadedModels) { model in
                                lmStudioModelRow(model)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }

                    // Available (not loaded) — collapsed summary
                    let unloaded = lm.models.filter { !$0.isLoaded }
                    if !unloaded.isEmpty {
                        Divider().opacity(0.3)
                        HStack {
                            Text("\(unloaded.count) more model\(unloaded.count == 1 ? "" : "s") available")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                }
            }
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

    private func lmStudioStatusBadge(_ lm: LMStudioMetrics) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(lm.status == .connected ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(lm.status == .connected ? "Connected" : "Offline")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func lmStudioResourceRow(_ lm: LMStudioMetrics) -> some View {
        let totalMem = metricsManager.currentSnapshot?.memory.totalBytes ?? 1
        let memPercent = Double(lm.processMemoryBytes) / Double(totalMem) * 100.0
        let memSeverity = MetricSeverity.from(percent: memPercent, warningAt: 40, criticalAt: 70)

        return HStack(spacing: 16) {
            // CPU
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("CPU")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", lm.processCPU))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(0.06))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.cyan.opacity(0.7))
                            .frame(width: geo.size.width * min(CGFloat(lm.processCPU / 100.0), 1.0))
                    }
                }
                .frame(height: 4)
            }

            // Memory
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("Memory")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatGBorMB(lm.processMemoryBytes))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(memSeverity.color)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(0.06))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(memSeverity.color.opacity(0.7))
                            .frame(width: geo.size.width * min(CGFloat(memPercent / 100.0), 1.0))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func lmStudioModelRow(_ model: LMStudioModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: model.type == "vlm" ? "eye" : model.type == "embeddings" ? "textformat.abc" : "text.bubble")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.modelId)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(model.arch)
                    Text(model.quantization)
                    if let loaded = model.loadedContextLength {
                        Text(formatContextLength(loaded) + " active")
                    } else {
                        Text(formatContextLength(model.maxContextLength))
                    }
                    Text(model.compatibilityType.uppercased())
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Text("Loaded")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.green.opacity(0.7)))
        }
    }

    private func formatContextLength(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return "\(tokens / 1_000_000)M ctx"
        }
        return "\(tokens / 1024)K ctx"
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


#Preview {
    DashboardView()
        .environmentObject(MetricsManager())
        .frame(width: 900, height: 700)
}
