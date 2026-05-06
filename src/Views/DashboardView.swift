import SwiftUI

enum DashboardTab: String, CaseIterable {
    case dashboard = "Dashboard"
    case processes = "Processes"
}

struct DashboardView: View {
    @EnvironmentObject private var metricsManager: MetricsManager
    @EnvironmentObject private var layout: DashboardLayout
    @State private var selectedTab: DashboardTab = .dashboard
    @State private var showingLayoutPopover = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
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
                    VStack(spacing: 10) {
                        LazyVGrid(columns: columns, spacing: 10) {
                            if layout.isVisible(.cpu)       { cpuCard }
                            if layout.isVisible(.memory)    { memoryCard }
                            if layout.isVisible(.gpu)       { gpuCard }
                            if layout.isVisible(.disk)      { diskCard }
                            if layout.isVisible(.network)   { networkCard }
                            if layout.isVisible(.thermal)   { thermalCard }
                            if metricsManager.currentSnapshot?.power != nil {
                                if layout.isVisible(.power)     { powerCard }
                                if layout.isVisible(.frequency) { frequencyCard }
                            }
                        }

                        bottomPanelsRow
                    }
                    .padding(12)
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
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Sparkline:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $metricsManager.timeRange) {
                        ForEach(TimeRange.allCases, id: \.self) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 80)
                }

                Spacer().frame(width: 8)

                Picker("", selection: $metricsManager.displayMode) {
                    ForEach(DisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                Spacer().frame(width: 12)

                Button {
                    showingLayoutPopover.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Show or hide widgets")
                .popover(isPresented: $showingLayoutPopover, arrowEdge: .bottom) {
                    layoutPopover
                }

                Spacer().frame(width: 8)
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

    // MARK: - Layout popover

    private var layoutPopover: some View {
        let supportsAS = Architecture.isAppleSilicon
        let widgets = DashboardWidget.allCases.filter { !$0.requiresAppleSilicon || supportsAS }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Widgets")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                ForEach(widgets) { widget in
                    Toggle(widget.displayName, isOn: Binding(
                        get: { layout.isVisible(widget) },
                        set: { layout.setVisible(widget, $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 220)
    }

    // MARK: - Bottom panels (Storage + AI backends, side by side)

    @ViewBuilder
    private var bottomPanelsRow: some View {
        let volumes = metricsManager.currentSnapshot?.disk.volumes ?? []
        let showVolumes  = layout.isVisible(.volumes) && !volumes.isEmpty
        let showLMStudio = layout.isVisible(.lmStudio)

        if showVolumes && showLMStudio {
            HStack(alignment: .top, spacing: 10) {
                VolumesPanelView(volumes: volumes)
                    .frame(maxWidth: .infinity)
                aiBackendsSection
                    .frame(width: 340)
            }
        } else if showVolumes {
            VolumesPanelView(volumes: volumes)
        } else if showLMStudio {
            aiBackendsSection
        }
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
            accentColor: .blue,
            sparklineFixedRange: isActual ? nil : (min: 0, max: 100),
            sparklineTimeRangeSeconds: selectedRange.seconds,
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
            accentColor: .purple,
            sparklineFixedRange: isActual ? nil : (min: 0, max: 100),
            sparklineTimeRangeSeconds: selectedRange.seconds,
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
            accentColor: .orange,
            sparklineFixedRange: isActual ? nil : (min: 0, max: 100),
            sparklineTimeRangeSeconds: selectedRange.seconds,
            sparklineValueFormatter: { String(format: "%.1f%%", $0) },
            details: [
                ("Utilization", String(format: "%.1f%%", usage), nil),
                ("Active Cores", String(format: "%.0f / %d", activeCores, coreCount), nil),
                ("Chip", snapshot?.gpu.chipName ?? "Apple Silicon", nil),
                ("Total Cores", "\(coreCount)", nil),
                ("Neural Engine", "\(snapshot?.gpu.neuralEngineCoreCount ?? 16) cores", nil),
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
            accentColor: .teal,
            sparklineTimeRangeSeconds: selectedRange.seconds,
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
            accentColor: .indigo,
            sparklineTimeRangeSeconds: selectedRange.seconds,
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

    private var powerCard: some View {
        let snapshot = metricsManager.currentSnapshot
        let power = snapshot?.power
        let total = power?.totalPowerWatts ?? 0
        let cpuW = power?.cpuPowerWatts ?? 0
        let gpuW = power?.gpuPowerWatts ?? 0
        let aneW = power?.anePowerWatts ?? 0
        return MetricCardView(
            title: "Power",
            icon: "bolt.fill",
            value: String(format: "%.2f W", total),
            subtitle: String(format: "CPU %.1f  GPU %.1f  ANE %.1f", cpuW, gpuW, aneW),
            severity: .from(percent: min(total / 80.0 * 100.0, 100.0), warningAt: 60, criticalAt: 85),
            sparklineData: metricsManager.history.totalPowerHistory(range: selectedRange),
            accentColor: .yellow,
            sparklineTimeRangeSeconds: selectedRange.seconds,
            sparklineValueFormatter: { String(format: "%.2f W", $0) },
            details: [
                ("CPU",   String(format: "%.2f W", cpuW), Color.blue),
                ("GPU",   String(format: "%.2f W", gpuW), Color.orange),
                ("ANE",   String(format: "%.2f W", aneW), Color.purple),
                ("Total", String(format: "%.2f W", total), nil),
            ]
        )
    }

    private var frequencyCard: some View {
        let snapshot = metricsManager.currentSnapshot
        let power = snapshot?.power
        let ecpu = power?.ecpuFreqMHz ?? 0
        let pcpu = power?.pcpuFreqMHz ?? 0
        let gpu = power?.gpuFreqMHz ?? 0
        return MetricCardView(
            title: "Frequency",
            icon: "waveform.path",
            value: pcpu > 0 ? String(format: "%.2f GHz", Double(pcpu) / 1000.0) : "—",
            subtitle: "P-CPU avg",
            severity: .normal,
            sparklineData: metricsManager.history.totalPowerHistory(range: selectedRange),
            accentColor: .mint,
            sparklineTimeRangeSeconds: selectedRange.seconds,
            sparklineValueFormatter: { String(format: "%.2f W", $0) },
            details: [
                ("E-CPU", ecpu > 0 ? "\(ecpu) MHz" : "idle", Color.cyan),
                ("P-CPU", pcpu > 0 ? "\(pcpu) MHz" : "idle", Color.blue),
                ("GPU",   gpu  > 0 ? "\(gpu) MHz"  : "idle", Color.orange),
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
            accentColor: .red,
            sparklineTimeRangeSeconds: selectedRange.seconds,
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
