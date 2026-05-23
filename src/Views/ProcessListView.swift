import SwiftUI

enum ProcessGrouping: String, CaseIterable {
    case application = "Application"
    case user = "User"
}

enum ProcessSortField: String {
    case name, user, cpu, memory
}

enum SortDirection {
    case ascending, descending

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

struct ProcessListView: View {
    let processes: [ProcessMetrics]
    var nameFilter: [String]? = nil
    var filterLabel: String = ""
    @State private var grouping: ProcessGrouping = .application
    @State private var expandedGroups: Set<String> = []
    @State private var sortField: ProcessSortField = .cpu
    @State private var sortDirection: SortDirection = .descending
    @State private var showAll = false
    @State private var bypassFilter = false

    private let defaultVisibleCount = 25

    private var activeFilter: [String]? {
        bypassFilter ? nil : nameFilter
    }

    private var totalProcessCount: Int {
        processes.reduce(0) { sum, p in
            sum + (p.isGroup ? p.children.count : 1)
        }
    }

    private func nameMatches(_ name: String, needles: [String]) -> Bool {
        let lower = name.lowercased()
        return needles.contains { lower.contains($0) }
    }

    private var filteredProcesses: [ProcessMetrics] {
        guard let filter = activeFilter else { return processes }
        let needles = filter.map { $0.lowercased() }
        return processes.compactMap { proc -> ProcessMetrics? in
            let parentMatched = nameMatches(proc.name, needles: needles)
            guard proc.isGroup else {
                return parentMatched ? proc : nil
            }
            if parentMatched { return proc }
            let matchingChildren = proc.children.filter { nameMatches($0.name, needles: needles) }
            guard !matchingChildren.isEmpty else { return nil }
            let cpu = matchingChildren.reduce(0.0) { $0 + $1.cpuUsage }
            let mem = matchingChildren.reduce(UInt64(0)) { $0 + $1.memoryBytes }
            return ProcessMetrics(
                pid: proc.pid,
                name: proc.name,
                user: proc.user,
                bundleIdentifier: proc.bundleIdentifier,
                cpuUsage: cpu,
                memoryBytes: mem,
                isGroup: true,
                children: matchingChildren
            )
        }
    }

    private var displayedProcesses: [ProcessMetrics] {
        let source = filteredProcesses
        let grouped: [ProcessMetrics]
        switch grouping {
        case .application:
            grouped = source
        case .user:
            grouped = groupByUser(source)
        }
        return sortProcesses(grouped)
    }

    private var maxCPU: Double {
        displayedProcesses.map(\.cpuUsage).max() ?? 1.0
    }

    private var maxMemory: UInt64 {
        displayedProcesses.map(\.memoryBytes).max() ?? 1
    }

    private func sortProcesses(_ procs: [ProcessMetrics]) -> [ProcessMetrics] {
        procs.sorted { a, b in
            let result: Bool
            switch sortField {
            case .name:
                result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .user:
                result = a.user.localizedCaseInsensitiveCompare(b.user) == .orderedAscending
            case .cpu:
                result = a.cpuUsage < b.cpuUsage
            case .memory:
                result = a.memoryBytes < b.memoryBytes
            }
            return sortDirection == .ascending ? result : !result
        }
    }

    private static let systemUsers: Set<String> = ["root", "nobody", "daemon"]

    private static func isSystemUser(_ user: String) -> Bool {
        user.hasPrefix("_") || systemUsers.contains(user)
    }

    private func groupByUser(_ procs: [ProcessMetrics]) -> [ProcessMetrics] {
        var flat: [ProcessMetrics] = []
        for p in procs {
            if p.isGroup {
                flat.append(contentsOf: p.children)
            } else {
                flat.append(p)
            }
        }

        var userGroups: [String: [ProcessMetrics]] = [:]
        var systemProcesses: [ProcessMetrics] = []

        for p in flat {
            if Self.isSystemUser(p.user) {
                systemProcesses.append(p)
            } else {
                userGroups[p.user, default: []].append(p)
            }
        }

        var results: [ProcessMetrics] = []

        for (user, members) in userGroups {
            let totalCPU = members.reduce(0.0) { $0 + $1.cpuUsage }
            let totalMem = members.reduce(UInt64(0)) { $0 + $1.memoryBytes }
            let sortedChildren = members.sorted { $0.cpuUsage > $1.cpuUsage }
            let topPID = sortedChildren.first?.pid ?? 0
            results.append(ProcessMetrics(
                pid: topPID,
                name: user,
                user: user,
                bundleIdentifier: nil,
                cpuUsage: totalCPU,
                memoryBytes: totalMem,
                isGroup: true,
                children: sortedChildren
            ))
        }

        if !systemProcesses.isEmpty {
            let totalCPU = systemProcesses.reduce(0.0) { $0 + $1.cpuUsage }
            let totalMem = systemProcesses.reduce(UInt64(0)) { $0 + $1.memoryBytes }
            let sortedChildren = systemProcesses.sorted { $0.cpuUsage > $1.cpuUsage }
            let topPID = sortedChildren.first?.pid ?? 0
            results.append(ProcessMetrics(
                pid: topPID,
                name: "System Services",
                user: "system",
                bundleIdentifier: nil,
                cpuUsage: totalCPU,
                memoryBytes: totalMem,
                isGroup: true,
                children: sortedChildren
            ))
        }

        return results
    }

    // MARK: - Resource Distribution Bar (User grouping)

    private static let groupColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .cyan, .mint, .indigo, .teal
    ]

    private func colorForGroup(index: Int, name: String) -> Color {
        if name == "System Services" { return .gray }
        return Self.groupColors[index % Self.groupColors.count]
    }

    @ViewBuilder
    private var resourceDistributionBar: some View {
        let groups = displayedProcesses
        let totalCPU = max(groups.reduce(0.0) { $0 + $1.cpuUsage }, 0.001)
        let totalMem = max(groups.reduce(UInt64(0)) { $0 + $1.memoryBytes }, 1)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("CPU")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)
                HStack(spacing: 1) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { idx, group in
                        let pct = group.cpuUsage / totalCPU
                        if pct > 0.005 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(colorForGroup(index: idx, name: group.name))
                                .frame(width: max(CGFloat(pct) * 300, 2), height: 14)
                                .help("\(group.name): \(String(format: "%.1f%%", group.cpuUsage))")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 0) {
                Text("Mem")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)
                HStack(spacing: 1) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { idx, group in
                        let pct = Double(group.memoryBytes) / Double(totalMem)
                        if pct > 0.005 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(colorForGroup(index: idx, name: group.name))
                                .frame(width: max(CGFloat(pct) * 300, 2), height: 14)
                                .help("\(group.name): \(formatBytesCompact(group.memoryBytes))")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 10) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { idx, group in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(colorForGroup(index: idx, name: group.name))
                            .frame(width: 7, height: 7)
                        Text("\(group.name) (\(group.isGroup ? "\(group.children.count)" : "1"))")
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func formatBytesCompact(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }

    // MARK: - Filter banner

    @ViewBuilder
    private var filterBanner: some View {
        let needles = nameFilter ?? []
        HStack(spacing: 8) {
            Image(systemName: bypassFilter ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(bypassFilter ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            if bypassFilter {
                Text("\(filterLabel) filter off — showing all processes")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                (Text("\(filterLabel): ").font(.system(size: 11, weight: .medium))
                 + Text(needles.joined(separator: ", "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary))
            }
            Spacer()
            Button(bypassFilter ? "Apply Filter" : "Show All") {
                bypassFilter.toggle()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(bypassFilter ? Color.clear : Color.accentColor.opacity(0.06))
    }

    // MARK: - Sorting

    private func toggleSort(_ field: ProcessSortField) {
        if sortField == field {
            sortDirection.toggle()
        } else {
            sortField = field
            sortDirection = field == .name || field == .user ? .ascending : .descending
        }
    }

    private func sortIndicator(for field: ProcessSortField) -> String {
        guard sortField == field else { return "" }
        return sortDirection == .ascending ? " \u{25B2}" : " \u{25BC}"
    }

    // MARK: - Build flat row list (avoids DisclosureGroup perf issues)

    private struct FlatRow: Identifiable {
        let id: String
        let process: ProcessMetrics
        let isChild: Bool
        let isGroupHeader: Bool
        let childCount: Int
    }

    private var flatRows: [FlatRow] {
        let source = showAll || displayedProcesses.count <= defaultVisibleCount
            ? displayedProcesses
            : Array(displayedProcesses.prefix(defaultVisibleCount))

        var rows: [FlatRow] = []
        for group in source {
            if group.children.isEmpty {
                rows.append(FlatRow(id: group.id, process: group, isChild: false, isGroupHeader: false, childCount: 0))
            } else {
                rows.append(FlatRow(id: "group-\(group.name)", process: group, isChild: false, isGroupHeader: true, childCount: group.children.count))
                if expandedGroups.contains(group.name) {
                    for child in group.children.sorted(by: { $0.cpuUsage > $1.cpuUsage }) {
                        rows.append(FlatRow(id: child.id, process: child, isChild: true, isGroupHeader: false, childCount: 0))
                    }
                }
            }
        }
        return rows
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .foregroundStyle(.secondary)
                Text("Processes")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Text("\(totalProcessCount) processes, \(displayedProcesses.count) \(grouping == .user ? "users" : "groups")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Picker("", selection: $grouping) {
                    ForEach(ProcessGrouping.allCases, id: \.self) { g in
                        Text(g.rawValue).tag(g)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .onChange(of: grouping) { _, _ in
                    expandedGroups = []
                    showAll = false
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if nameFilter != nil {
                Divider()
                filterBanner
            }

            if grouping == .user {
                Divider()
                resourceDistributionBar
            }

            Divider()

            columnHeaders
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

            Divider()

            // Flat row list — no DisclosureGroup, just simple VStack
            ScrollView {
                LazyVStack(spacing: 0) {
                    let rows = flatRows
                    let cpuMax = maxCPU
                    let memMax = maxMemory
                    let showUserCol = grouping == .application

                    ForEach(rows) { row in
                        if row.isGroupHeader {
                            GroupHeaderRow(
                                process: row.process,
                                childCount: row.childCount,
                                isExpanded: expandedGroups.contains(row.process.name),
                                showUser: showUserCol,
                                maxCPU: cpuMax,
                                maxMemory: memMax
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if expandedGroups.contains(row.process.name) {
                                    expandedGroups.remove(row.process.name)
                                } else {
                                    expandedGroups.insert(row.process.name)
                                }
                            }
                        } else {
                            ProcessRowContent(
                                process: row.process,
                                isChild: row.isChild,
                                showUser: showUserCol,
                                maxCPU: cpuMax,
                                maxMemory: memMax
                            )
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                        }

                        Divider()
                            .padding(.leading, 14)
                    }

                    if displayedProcesses.count > defaultVisibleCount {
                        Button {
                            showAll.toggle()
                        } label: {
                            Text(showAll ? "Show Top \(defaultVisibleCount)" : "Show All \(displayedProcesses.count) Groups")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.blue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
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

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            sortableHeader(grouping == .user ? "User / Process" : "Application", field: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            if grouping == .application {
                sortableHeader("User", field: .user)
                    .frame(width: 100, alignment: .trailing)
                    .padding(.trailing, 12)
            }
            sortableHeader("CPU", field: .cpu)
                .frame(width: 80, alignment: .trailing)
                .padding(.trailing, 12)
            sortableHeader("Memory", field: .memory)
                .frame(width: 80, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
    }

    private func sortableHeader(_ label: String, field: ProcessSortField) -> some View {
        Button(action: { toggleSort(field) }) {
            HStack(spacing: 2) {
                Text(label + sortIndicator(for: field))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(sortField == field ? .secondary : .tertiary)
    }
}

// MARK: - Group Header Row (tap to expand, no DisclosureGroup)

private struct GroupHeaderRow: View {
    let process: ProcessMetrics
    let childCount: Int
    let isExpanded: Bool
    let showUser: Bool
    let maxCPU: Double
    let maxMemory: UInt64

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)

                Text(process.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("\(childCount)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showUser {
                Text(process.user)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 100, alignment: .trailing)
                    .padding(.trailing, 12)
            }

            cpuText(process.cpuUsage)
                .frame(width: 80, alignment: .trailing)
                .padding(.trailing, 12)

            memoryText(process.memoryBytes)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.02))
    }

    private func cpuText(_ value: Double) -> some View {
        Text(String(format: "%5.1f%%", value))
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(value >= 80 ? .red : value >= 40 ? .orange : .primary)
    }

    private func memoryText(_ bytes: UInt64) -> some View {
        Text(formatBytes(bytes))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes == 0 { return "—" }
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 { return String(format: "%5.1f GB", mb / 1024) }
        return String(format: "%5.0f MB", mb)
    }
}

// MARK: - Process Row

struct ProcessRowContent: View {
    let process: ProcessMetrics
    let isChild: Bool
    let showUser: Bool
    let maxCPU: Double
    let maxMemory: UInt64

    private var isRestricted: Bool {
        process.cpuUsage == 0 && process.memoryBytes == 0
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if isChild {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
                Text(process.name)
                    .font(.system(size: 12, weight: isChild ? .regular : .medium))
                    .foregroundStyle(isRestricted && isChild ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isRestricted && isChild {
                    Text("restricted")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.04)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showUser {
                Text(process.user)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 100, alignment: .trailing)
                    .padding(.trailing, 12)
            }

            Text(formatCPU(process.cpuUsage))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(colorForCPU(process.cpuUsage))
                .frame(width: 80, alignment: .trailing)
                .padding(.trailing, 12)

            Text(formatBytes(process.memoryBytes))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }

    private func formatCPU(_ value: Double) -> String {
        if value == 0 { return "—" }
        return String(format: "%5.1f%%", value)
    }

    private func colorForCPU(_ value: Double) -> Color {
        if value >= 80 { return .red }
        if value >= 40 { return .orange }
        return .primary
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes == 0 { return "—" }
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%5.1f GB", mb / 1024)
        }
        return String(format: "%5.0f MB", mb)
    }
}

#Preview {
    let sampleProcesses: [ProcessMetrics] = [
        ProcessMetrics(pid: 100, name: "Safari", user: "michaeljoseph",
                       bundleIdentifier: "com.apple.Safari",
                       cpuUsage: 18.3, memoryBytes: 820_000_000, isGroup: true,
                       children: [
                           ProcessMetrics(pid: 101, name: "Web Content", user: "michaeljoseph",
                                          bundleIdentifier: nil,
                                          cpuUsage: 12.1, memoryBytes: 500_000_000, isGroup: false, children: []),
                           ProcessMetrics(pid: 102, name: "Networking", user: "michaeljoseph",
                                          bundleIdentifier: nil,
                                          cpuUsage: 6.2, memoryBytes: 320_000_000, isGroup: false, children: [])
                       ]),
        ProcessMetrics(pid: 200, name: "kernel_task", user: "root",
                       bundleIdentifier: nil,
                       cpuUsage: 45.0, memoryBytes: 2_400_000_000, isGroup: false, children: []),
        ProcessMetrics(pid: 300, name: "Finder", user: "michaeljoseph",
                       bundleIdentifier: "com.apple.finder",
                       cpuUsage: 0.8, memoryBytes: 120_000_000, isGroup: false, children: [])
    ]

    ProcessListView(processes: sampleProcesses)
        .frame(width: 600, height: 300)
        .padding()
}
