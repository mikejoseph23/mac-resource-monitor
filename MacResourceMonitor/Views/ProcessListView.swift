import SwiftUI

enum ProcessGrouping: String, CaseIterable {
    case application = "Application"
    case user = "User"
}

struct ProcessListView: View {
    let processes: [ProcessMetrics]
    @State private var grouping: ProcessGrouping = .application
    @State private var expandedGroups: Set<String> = []

    private var displayedProcesses: [ProcessMetrics] {
        switch grouping {
        case .application:
            return processes.sorted { $0.cpuUsage > $1.cpuUsage }
        case .user:
            return groupByUser(processes)
        }
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

        var groups: [String: [ProcessMetrics]] = [:]
        for p in flat {
            groups[p.user, default: []].append(p)
        }

        var results: [ProcessMetrics] = []
        for (user, members) in groups {
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
        return results.sorted { $0.cpuUsage > $1.cpuUsage }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .foregroundStyle(.secondary)
                Text("Processes")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Text("\(displayedProcesses.count) \(grouping == .user ? "users" : "apps")")
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
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Column headers
            columnHeaders
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

            Divider()

            // Process rows
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(displayedProcesses) { process in
                        if process.children.isEmpty {
                            ProcessRowView(process: process, isChild: false, showUser: grouping == .application)
                        } else {
                            let isExpanded = Binding<Bool>(
                                get: { expandedGroups.contains(process.name) },
                                set: { newVal in
                                    if newVal {
                                        expandedGroups.insert(process.name)
                                    } else {
                                        expandedGroups.remove(process.name)
                                    }
                                }
                            )
                            DisclosureGroup(isExpanded: isExpanded) {
                                ForEach(process.children.sorted(by: { $0.cpuUsage > $1.cpuUsage })) { child in
                                    ProcessRowView(process: child, isChild: true, showUser: grouping == .application)
                                }
                            } label: {
                                ProcessRowContent(process: process, isChild: false, showUser: grouping == .application)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                        }

                        Divider()
                            .padding(.leading, 14)
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
        processRowLayout(
            name: Text(grouping == .user ? "User / Process" : "Application"),
            user: grouping == .application ? Text("User") : nil,
            cpu: Text("CPU"),
            memory: Text("Memory")
        )
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
    }

    private func processRowLayout(name: Text, user: Text?, cpu: Text, memory: Text) -> some View {
        HStack(spacing: 0) {
            name.frame(maxWidth: .infinity, alignment: .leading)
            if let user = user {
                user.frame(width: 140, alignment: .trailing)
                    .padding(.trailing, 12)
            }
            cpu.frame(width: 60, alignment: .trailing)
                .padding(.trailing, 12)
            memory.frame(width: 70, alignment: .trailing)
        }
    }
}

// MARK: - Row

private struct ProcessRowView: View {
    let process: ProcessMetrics
    let isChild: Bool
    let showUser: Bool

    var body: some View {
        ProcessRowContent(process: process, isChild: isChild, showUser: showUser)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
    }
}

private struct ProcessRowContent: View {
    let process: ProcessMetrics
    let isChild: Bool
    let showUser: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Name
            HStack(spacing: 6) {
                if isChild {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
                Text(process.name)
                    .font(.system(size: 12, weight: isChild ? .regular : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // User column (only in application grouping)
            if showUser {
                Text(process.user)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 140, alignment: .trailing)
                    .padding(.trailing, 12)
            }

            // CPU
            Text(formatCPU(process.cpuUsage))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(colorForCPU(process.cpuUsage))
                .frame(width: 60, alignment: .trailing)
                .padding(.trailing, 12)

            // Memory
            Text(formatBytes(process.memoryBytes))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
    }

    private func formatCPU(_ value: Double) -> String {
        return String(format: "%5.1f%%", value)
    }

    private func colorForCPU(_ value: Double) -> Color {
        if value >= 80 { return .red }
        if value >= 40 { return .orange }
        return .primary
    }

    private func formatBytes(_ bytes: UInt64) -> String {
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
