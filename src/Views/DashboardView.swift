import SwiftUI

enum DashboardTab: String, CaseIterable {
    case dashboard = "Dashboard"
    case processes = "Processes"
}

private struct DashboardWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 900
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct DashboardView: View {
    @EnvironmentObject private var metricsManager: MetricsManager
    @EnvironmentObject private var layout: DashboardLayout
    @State private var selectedTab: DashboardTab = .dashboard
    @State private var contentWidth: CGFloat = 900

    private let columnCount = 3
    private let columnSpacing: CGFloat = 10
    private let horizontalInset: CGFloat = 50

    /// Upper bound on the dashboard content width. Below this the layout stays
    /// fully responsive; above it the content stops stretching and the extra
    /// window width becomes centered side margins — so little panels never go
    /// full-bleed and sparse on a big display.
    private let contentMaxWidth: CGFloat = 1180

    private var thermalVisible: Bool { shouldRender(.thermal) }

    /// Default-profile grid cards, **excluding** Thermal. Thermal is placed
    /// last — either filling a trailing gap in the grid, or leading the bottom
    /// panel row — so it never sits orphaned with two empty columns beside it.
    private var gridCardWidgets: [DashboardWidget] {
        layout.orderedGridWidgets().filter { $0 != .thermal && shouldRender($0) }
    }

    /// `gridCardWidgets` chunked into rows of `columnCount` (all span 1 in the
    /// default profile).
    private var gridRows: [[DashboardWidget]] {
        stride(from: 0, to: gridCardWidgets.count, by: columnCount).map {
            Array(gridCardWidgets[$0..<min($0 + columnCount, gridCardWidgets.count)])
        }
    }

    /// True when the last grid row has exactly one empty column, so Thermal can
    /// slot in to complete a full 3×N grid (e.g. Mac Studio with Power +
    /// Frequency → 8 cards → 3,3,2 + Thermal = perfect 3,3,3). When false,
    /// Thermal drops to the bottom row alongside the Storage / AI panels.
    private var thermalFillsGridGap: Bool {
        guard thermalVisible, let last = gridRows.last else { return false }
        return last.count == columnCount - 1
    }

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
                        Color.clear
                            .frame(height: 0)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear
                                        .preference(key: DashboardWidthKey.self,
                                                    value: proxy.size.width)
                                }
                            )
                        if layout.activeProfile.emphasized.isEmpty {
                            uniformGridLayout
                        } else {
                            twoColumnLayout
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, 12)
                    // Cap the content width and center it, so beyond the cap the
                    // window grows side margins instead of stretching the cards
                    // and bottom panels full-bleed.
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .onPreferenceChange(DashboardWidthKey.self) { newWidth in
                    let usable = max(newWidth - horizontalInset * 2, 200)
                    if abs(usable - contentWidth) > 0.5 {
                        contentWidth = usable
                    }
                }

            case .processes:
                if let snapshot = metricsManager.currentSnapshot {
                    ProcessListView(
                        processes: snapshot.processes,
                        nameFilter: layout.activeProfile.processNameFilter,
                        filterLabel: layout.activeProfile.displayName
                    )
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
        HStack(spacing: 12) {
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
                Picker("", selection: $layout.activeProfile) {
                    ForEach(DashboardProfile.allCases) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                .help("Dashboard profile — reorders cards and filters processes for a use case")

                Picker("", selection: $metricsManager.timeRange) {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .help("Sparkline time range")

                Picker("", selection: $metricsManager.displayMode) {
                    ForEach(DisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            // Running indicator
            Circle()
                .fill(metricsManager.isRunning ? Color.green : Color.gray)
                .frame(width: 7, height: 7)
                .help(metricsManager.isRunning ? "Live" : "Paused")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Dashboard layouts

    /// Default profile: uniform 3-column grid of metric cards, with Thermal +
    /// the Storage / AI panels spread horizontally across the bottom so nothing
    /// sits orphaned and the lower widgets stay in view without deep scrolling.
    private var uniformGridLayout: some View {
        let fillGap = thermalFillsGridGap
        let stacked = contentWidth < 720
        // Build the render rows, appending Thermal to the last row when it fills
        // the trailing grid gap. `equalWidthRow` then lays each row out as equal
        // flexible columns, padding short rows so the grid stretches to the full
        // content width and lines up edge-to-edge with the bottom panels.
        var rows = gridRows
        if fillGap, !rows.isEmpty {
            rows[rows.count - 1].append(.thermal)
        }
        return VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                equalWidthRow(row, stacked: stacked) { widget in
                    card(for: widget, emphasized: false, compact: false)
                }
            }

            bottomRegion(includeThermal: thermalVisible && !fillGap)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Profiles with emphasis (e.g. Local Inference): featured cards spread
    /// across the top in a row, the remaining compact cards in a grid beneath
    /// them, and the Storage / AI panels side by side at the bottom. Laying it
    /// out in horizontal bands (instead of two tall stacked columns) uses the
    /// available width and keeps the whole dashboard in view without a deep
    /// vertical scroll on a laptop. Falls back to a single stack when narrow.
    private var twoColumnLayout: some View {
        let widgets = layout.orderedGridWidgets().filter { shouldRender($0) }
        let featured = widgets.filter { layout.activeProfile.emphasized.contains($0) }
        let compactList = widgets.filter { !layout.activeProfile.emphasized.contains($0) }
        let compactRows = stride(from: 0, to: compactList.count, by: columnCount).map {
            Array(compactList[$0..<min($0 + columnCount, compactList.count)])
        }
        let stacked = contentWidth < 720

        return VStack(spacing: 10) {
            // Featured hero cards, spread evenly across the top. `fillHeight`
            // keeps every card in the row the same height as its tallest peer.
            equalWidthRow(featured, stacked: stacked, fillHeight: true) { widget in
                card(for: widget, emphasized: true, compact: false)
            }

            // Remaining metrics as a responsive grid of compact cards, each row
            // height-matched so Frequency/Thermal don't render stubby next to a
            // taller CPU, and Disk matches Disk I/O and Network.
            ForEach(Array(compactRows.enumerated()), id: \.offset) { _, row in
                equalWidthRow(row, stacked: stacked, fillHeight: true) { widget in
                    card(for: widget, emphasized: false, compact: true)
                }
            }

            // Storage Volumes + Local AI Models, side by side at the bottom.
            bottomRegion(includeThermal: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Lays `widgets` out as equal-width columns in a row (stacking vertically
    /// on a narrow window). Each card fills its share of the width via
    /// `maxWidth: .infinity`, so the row scales with the available space. When
    /// `fillHeight` is set, every card also fills the row's height (which the
    /// HStack sizes to the tallest card), so cards in a row share matching
    /// top/bottom edges instead of sizing to their own intrinsic content.
    @ViewBuilder
    private func equalWidthRow(
        _ widgets: [DashboardWidget],
        stacked: Bool,
        fillHeight: Bool = false,
        @ViewBuilder card: @escaping (DashboardWidget) -> some View
    ) -> some View {
        if stacked {
            VStack(spacing: 10) {
                ForEach(widgets) { widget in
                    card(widget).frame(maxWidth: .infinity)
                }
            }
        } else {
            HStack(alignment: .top, spacing: columnSpacing) {
                ForEach(widgets) { widget in
                    card(widget)
                        .frame(maxWidth: .infinity,
                               maxHeight: fillHeight ? .infinity : nil,
                               alignment: .top)
                }
                // Pad a short final row so its cards keep the grid's column
                // width instead of stretching to fill the leftover space. The
                // spacer also fills height so it doesn't collapse the row.
                if widgets.count < columnCount {
                    ForEach(0..<(columnCount - widgets.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity,
                                          maxHeight: fillHeight ? .infinity : nil)
                    }
                }
            }
        }
    }

    // MARK: - Bottom region (Thermal + Storage + AI backends, spread across)

    /// Lays Thermal (when not already filling a grid gap), Storage Volumes and
    /// Local AI Models out as equal-width columns so the lower widgets sit in
    /// the visible viewport instead of stacking into a tall scroll. Falls back
    /// to a vertical stack on a narrow window.
    @ViewBuilder
    private func bottomRegion(includeThermal: Bool) -> some View {
        let volumes = metricsManager.currentSnapshot?.disk.volumes ?? []
        let showVolumes  = layout.isVisible(.volumes) && !volumes.isEmpty
        let showLMStudio = layout.isVisible(.lmStudio)
        let hasAny = includeThermal || showVolumes || showLMStudio
        let stacked = contentWidth < 720

        if hasAny {
            let panels = Group {
                if includeThermal {
                    card(for: .thermal, emphasized: false, compact: false)
                        .frame(maxWidth: .infinity)
                }
                if showVolumes {
                    VolumesPanelView(volumes: volumes)
                        .frame(maxWidth: .infinity)
                }
                if showLMStudio {
                    aiBackendsSection
                        .frame(maxWidth: .infinity)
                }
            }

            if stacked {
                VStack(spacing: 10) { panels }
            } else {
                HStack(alignment: .top, spacing: 10) { panels }
            }
        }
    }

    // MARK: - Cards

    private func shouldRender(_ widget: DashboardWidget) -> Bool {
        guard layout.isVisible(widget) else { return false }
        if widget == .power || widget == .frequency {
            return metricsManager.currentSnapshot?.power != nil
        }
        return true
    }

    @ViewBuilder
    private func card(for widget: DashboardWidget, emphasized: Bool, compact: Bool) -> some View {
        switch widget {
        case .cpu:        cpuCard(emphasized: emphasized, compact: compact)
        case .memory:     memoryCard(emphasized: emphasized, compact: compact)
        case .gpu:        gpuCard(emphasized: emphasized, compact: compact)
        case .disk:       diskCard(emphasized: emphasized, compact: compact)
        case .diskIO:     diskIOCard(emphasized: emphasized, compact: compact)
        case .network:    networkCard(emphasized: emphasized, compact: compact)
        case .thermal:    thermalCard(emphasized: emphasized, compact: compact)
        case .power:      powerCard(emphasized: emphasized, compact: compact)
        case .frequency:  frequencyCard(emphasized: emphasized, compact: compact)
        case .volumes, .lmStudio:
            // Rendered in bottomPanelsRow, not in the grid.
            EmptyView()
        }
    }

    private func cpuCard(emphasized: Bool, compact: Bool) -> some View {
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
            ],
            emphasized: emphasized,
            compact: compact,
            gaugeFraction: usage / 100.0
        )
    }

    private func memoryCard(emphasized: Bool, compact: Bool) -> some View {
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
            ],
            emphasized: emphasized,
            compact: compact,
            gaugeFraction: usage / 100.0
        )
    }

    private func gpuCard(emphasized: Bool, compact: Bool) -> some View {
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
            ],
            emphasized: emphasized,
            compact: compact,
            gaugeFraction: usage / 100.0
        )
    }

    /// Disk **capacity** card — how full the boot volume is. Capacity and I/O
    /// throughput are unrelated metrics, so they live on separate cards now
    /// (the old combined card paired a capacity gauge with an I/O sparkline).
    private func diskCard(emphasized: Bool, compact: Bool) -> some View {
        let disk = metricsManager.currentSnapshot?.disk
        let totalBytes = Double(disk?.totalDiskSpace ?? 0)
        let usedBytes = Double(disk?.usedDiskSpace ?? 0)
        let freeBytes = max(totalBytes - usedBytes, 0)
        let usagePercent = totalBytes > 0 ? (usedBytes / totalBytes) * 100 : 0
        return MetricCardView(
            title: "Disk",
            icon: "internaldrive",
            value: String(format: "%.0f%%", usagePercent),
            subtitle: formatDiskSpace(used: usedBytes, total: totalBytes),
            severity: .capacity(usagePercent),
            sparklineData: [],
            accentColor: .teal,
            details: [
                ("Used", formatGBorMB(disk?.usedDiskSpace ?? 0), nil),
                ("Free", formatGBorMB(UInt64(freeBytes)), nil),
                ("Total", formatGBorMB(disk?.totalDiskSpace ?? 0), nil),
            ],
            emphasized: emphasized,
            compact: compact,
            gaugeFraction: usagePercent / 100.0
        )
    }

    /// Disk **I/O** card — live read/write throughput. Split out from the
    /// capacity card so the sparkline plots the metric the headline describes.
    private func diskIOCard(emphasized: Bool, compact: Bool) -> some View {
        let disk = metricsManager.currentSnapshot?.disk
        let readRate = disk?.readBytesPerSec ?? 0
        let writeRate = disk?.writeBytesPerSec ?? 0
        let combinedRate = readRate + writeRate
        return MetricCardView(
            title: "Disk I/O",
            icon: "arrow.up.arrow.down",
            value: formatIORate(combinedRate),
            subtitle: String(format: "R: %@  W: %@", formatIORate(readRate), formatIORate(writeRate)),
            severity: .normal,
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
            ],
            emphasized: emphasized,
            compact: compact
        )
    }

    private func networkCard(emphasized: Bool, compact: Bool) -> some View {
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
            ],
            emphasized: emphasized,
            compact: compact
        )
    }

    private func powerCard(emphasized: Bool, compact: Bool) -> some View {
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
            ],
            emphasized: emphasized,
            compact: compact
        )
    }

    private func frequencyCard(emphasized: Bool, compact: Bool) -> some View {
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
            sparklineData: metricsManager.history.pcpuFrequencyHistory(range: selectedRange),
            accentColor: .mint,
            sparklineTimeRangeSeconds: selectedRange.seconds,
            sparklineValueFormatter: { String(format: "%.2f GHz", $0) },
            details: [
                ("E-CPU", ecpu > 0 ? "\(ecpu) MHz" : "idle", Color.cyan),
                ("P-CPU", pcpu > 0 ? "\(pcpu) MHz" : "idle", Color.blue),
                ("GPU",   gpu  > 0 ? "\(gpu) MHz"  : "idle", Color.orange),
            ],
            emphasized: emphasized,
            compact: compact
        )
    }

    private func thermalCard(emphasized: Bool, compact: Bool) -> some View {
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
            sparklineData: [],
            accentColor: .red,
            sparklineTimeRangeSeconds: selectedRange.seconds,
            details: [
                ("State", label, nil),
                ("Throttled", isThrottled ? "Yes" : "No", nil),
                ("CPU Load", String(format: "%.1f%%", cpuUsage), nil),
                ("GPU Load", String(format: "%.1f%%", gpuUsage), nil),
                ("Pressure", snapshot?.memory.pressureLevel.rawValue ?? "N/A", nil),
            ],
            emphasized: emphasized,
            compact: compact
        )
    }

    // MARK: - AI Backends

    private var aiBackendsSection: some View {
        let snapshot = metricsManager.currentSnapshot
        let lm = snapshot?.lmStudio ?? .offline
        let omlx = snapshot?.omlx ?? .offline
        let ollama = snapshot?.ollama ?? .offline
        let onlineCount = [lm.status == .connected, omlx.isOnline, ollama.isOnline].filter { $0 }.count

        return VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "brain")
                    .foregroundStyle(.secondary)
                Text("Local AI Models")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                backendsStatusBadge(onlineCount: onlineCount, total: 3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            lmStudioBackend(lm)

            Divider().opacity(0.5)

            omlxBackend(omlx)

            Divider().opacity(0.5)

            ollamaBackend(ollama)
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

    private func backendsStatusBadge(onlineCount: Int, total: Int) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(onlineCount > 0 ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(onlineCount > 0 ? "\(onlineCount) of \(total) running" : "None running")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// One backend's title row: icon, name, and a right-hand summary that reads
    /// as the status when the server is down.
    private func backendSummaryRow(icon: String,
                                   name: String,
                                   tint: Color,
                                   summary: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(name)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func backendOfflineRow(icon: String, name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.gray)
                .frame(width: 20)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Color.gray).frame(width: 6, height: 6)
                Text("Not Running")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Small grey caption under a backend's model list (tok/s, memory, queue).
    private func backendStatsRow(_ items: [String]) -> some View {
        HStack(spacing: 10) {
            ForEach(items, id: \.self) { item in
                Text(item)
            }
            Spacer()
        }
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func moreModelsRow(_ count: Int) -> some View {
        HStack {
            Text("\(count) more model\(count == 1 ? "" : "s") available")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: LM Studio

    @ViewBuilder
    private func lmStudioBackend(_ lm: LMStudioMetrics) -> some View {
        switch lm.status {
        case .offline:
            backendOfflineRow(icon: "server.rack", name: "LM Studio")

        case .connected:
            VStack(spacing: 0) {
                backendSummaryRow(
                    icon: "server.rack",
                    name: "LM Studio",
                    tint: .green,
                    summary: "\(lm.loadedCount) loaded / \(lm.availableCount) available"
                )

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

                let unloaded = lm.models.filter { !$0.isLoaded }
                if !unloaded.isEmpty {
                    Divider().opacity(0.3)
                    moreModelsRow(unloaded.count)
                }
            }
        }
    }

    // MARK: oMLX

    @ViewBuilder
    private func omlxBackend(_ omlx: OMLXMetrics) -> some View {
        switch omlx.status {
        case .offline:
            backendOfflineRow(icon: "cpu.fill", name: "oMLX")

        case .loading, .connected:
            let loading = omlx.status == .loading
            VStack(spacing: 0) {
                backendSummaryRow(
                    icon: "cpu.fill",
                    name: "oMLX",
                    tint: loading ? .orange : .green,
                    summary: loading
                        ? "Preloading models…"
                        : "\(omlx.loadedCount) loaded / \(omlx.discoveredCount) discovered"
                )

                // Model names only come from the authenticated /api/status; with
                // just /health we fall back to naming the default model.
                let names = omlx.detailed
                    ? omlx.loadedModels
                    : [omlx.defaultModel].compactMap { $0 }

                if !names.isEmpty {
                    Divider().opacity(0.3)
                    VStack(spacing: 6) {
                        ForEach(names, id: \.self) { name in
                            omlxModelRow(name: name,
                                         isDefault: name == omlx.defaultModel,
                                         resident: omlx.detailed)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, omlxStats(omlx).isEmpty ? 10 : 6)
                }

                let stats = omlxStats(omlx)
                if !stats.isEmpty {
                    backendStatsRow(stats)
                }
            }
        }
    }

    private func omlxStats(_ omlx: OMLXMetrics) -> [String] {
        var stats: [String] = []
        if omlx.modelMemoryUsedBytes > 0 {
            if let max = omlx.modelMemoryMaxBytes, max > 0 {
                stats.append("\(formatGBorMB(omlx.modelMemoryUsedBytes)) / \(formatGBorMB(max))")
            } else {
                stats.append(formatGBorMB(omlx.modelMemoryUsedBytes))
            }
        }
        if let tps = omlx.generationTPS, tps > 0 {
            stats.append(String(format: "%.0f tok/s gen", tps))
        }
        if let prefill = omlx.prefillTPS, prefill > 0 {
            stats.append(String(format: "%.0f tok/s prefill", prefill))
        }
        if omlx.activeRequests > 0 || omlx.waitingRequests > 0 {
            stats.append("\(omlx.activeRequests) active, \(omlx.waitingRequests) queued")
        }
        if let cache = omlx.cacheEfficiency, cache > 0 {
            stats.append(String(format: "%.0f%% cache", cache <= 1 ? cache * 100 : cache))
        }
        if omlx.loadingCount > 0 {
            stats.append("\(omlx.loadingCount) loading")
        }
        return stats
    }

    private func omlxModelRow(name: String, isDefault: Bool, resident: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .frame(width: 16)

            Text(name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            if isDefault {
                Text("DEFAULT")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if resident {
                Text("Loaded")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.7)))
            }
        }
    }

    // MARK: Ollama

    @ViewBuilder
    private func ollamaBackend(_ ollama: OllamaMetrics) -> some View {
        switch ollama.status {
        case .offline:
            backendOfflineRow(icon: "shippingbox", name: "Ollama")

        case .connected:
            VStack(spacing: 0) {
                backendSummaryRow(
                    icon: "shippingbox",
                    name: "Ollama",
                    tint: .green,
                    summary: "\(ollama.loadedCount) loaded / \(ollama.installedCount) installed"
                )

                if !ollama.loadedModels.isEmpty {
                    Divider().opacity(0.3)
                    VStack(spacing: 6) {
                        ForEach(ollama.loadedModels) { model in
                            ollamaModelRow(model)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }

                let idle = ollama.installedCount - ollama.loadedCount
                if ollama.loadedModels.isEmpty && idle > 0 {
                    Divider().opacity(0.3)
                    moreModelsRow(idle)
                }
            }
        }
    }

    private func ollamaModelRow(_ model: OllamaModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let family = model.family { Text(family) }
                    if let params = model.parameterSize { Text(params) }
                    if let quant = model.quantization { Text(quant) }
                    Text(formatGBorMB(model.sizeBytes))
                    // A partial offload means part of the model is running off
                    // CPU memory — worth flagging, since it tanks tok/s.
                    if !model.isFullyOnGPU && model.sizeBytes > 0 {
                        Text("\(formatGBorMB(model.vramBytes)) on GPU")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            }

            Spacer()

            if let expires = model.expiresAt {
                Text(expiryLabel(expires))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Ollama's keep-alive countdown. Far-future expiries mean `keep_alive: -1`.
    private func expiryLabel(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds > 60 * 60 * 24 * 365 { return "pinned" }
        if seconds <= 0 { return "unloading" }
        if seconds < 60 { return "\(Int(seconds))s left" }
        if seconds < 3600 { return "\(Int(seconds / 60))m left" }
        return "\(Int(seconds / 3600))h left"
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
