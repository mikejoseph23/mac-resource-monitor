import SwiftUI

/// What LM Studio and oMLX are keeping on this disk from your prompts.
///
/// Sibling to `VolumesPanelView` in the bottom region, and shaped like it, but
/// backed by `AIStorageModel` rather than the 2s snapshot — see that type for
/// why this one keeps its own cadence.
struct AIStoragePanelView: View {
    @ObservedObject var model: AIStorageModel = .shared

    @State private var showingPurge = false
    @State private var showingSearch = false
    @State private var showingExplore = false

    /// Re-rendered every tick by the dashboard, so "last scanned" ages on its
    /// own without a second timer here.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                summaryLine

                if let snapshot = model.snapshot {
                    let providers = snapshot.presentProviders
                    if providers.isEmpty {
                        emptyState
                    } else {
                        ForEach(providers) { provider in
                            providerSection(provider, targets: snapshot.targets(for: provider))
                        }
                    }
                } else if !model.isScanning {
                    emptyState
                }

                if model.snapshot?.presentProviders.isEmpty == false {
                    actions
                }
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
        .onAppear { model.scanIfStale() }
        .sheet(isPresented: $showingPurge) {
            AIStoragePurgeSheet(model: model)
        }
        .sheet(isPresented: $showingSearch) {
            AIStorageSearchSheet(model: model)
        }
        .sheet(isPresented: $showingExplore) {
            AIStorageLogsSheet(model: model)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "externaldrive.badge.person.crop")
                .foregroundStyle(.secondary)
            Text("Local AI Storage")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                model.rescan()
            } label: {
                if model.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .disabled(model.isScanning)
            .foregroundStyle(.tertiary)
            .help("Rescan")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summaryLine: some View {
        HStack(spacing: 6) {
            if let snapshot = model.snapshot {
                Text(formatBytes(snapshot.totalBytes))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("retained")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(model.isScanning ? "scanning…" : "last scanned \(relativeAge(snapshot.scannedAt))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else if model.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                Text("scanning…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("not scanned yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        Text("No LM Studio or oMLX data found on this Mac.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }

    // MARK: - Sections

    private func providerSection(_ provider: AIStorageProvider, targets: [AIStorageTarget]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: provider.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(provider.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 5) {
                ForEach(targets.filter(\.exists)) { target in
                    targetRow(target)
                }
            }
        }
    }

    private func targetRow(_ target: AIStorageTarget) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(target.label)
                    .font(.system(size: 12))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(formatBytes(target.sizeBytes))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(target.noteIsWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))

                if let note = target.note {
                    HStack(spacing: 3) {
                        if target.noteIsWarning {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                        }
                        Text(note)
                            .lineLimit(1)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(target.noteIsWarning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    .frame(width: 118, alignment: .leading)
                }
            }
            .help("\(target.displayPath) — \(target.contents)")

            if let fraction = target.capFraction {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(0.06))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(MetricSeverity.from(percent: fraction * 100,
                                                      warningAt: 80,
                                                      criticalAt: 95).color.opacity(0.7))
                            .frame(width: geometry.size.width * CGFloat(fraction))
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private var actions: some View {
        HStack {
            Button("Search retained text…") { showingSearch = true }
                .controlSize(.small)
            Button("Explore logs…") { showingExplore = true }
                .controlSize(.small)
                .disabled(model.snapshot?.containsExplorable != true)
                .help("Read the retained logs and conversations — read-only")
            Spacer()
            Button("Purge…") { showingPurge = true }
                .controlSize(.small)
                .disabled(model.snapshot == nil)
        }
        .padding(.top, 2)
    }

    // MARK: - Formatting

    private func relativeAge(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let tb = Double(bytes) / (1024 * 1024 * 1024 * 1024)
        if tb >= 1.0 { return String(format: "%.1f TB", tb) }
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1.0 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1024
        if kb >= 1.0 { return String(format: "%.0f KB", kb) }
        return "\(bytes) B"
    }
}

/// Shared byte formatter for the storage sheets, matching the panel's idiom.
func aiStorageFormatBytes(_ bytes: UInt64) -> String {
    let tb = Double(bytes) / (1024 * 1024 * 1024 * 1024)
    if tb >= 1.0 { return String(format: "%.1f TB", tb) }
    let gb = Double(bytes) / (1024 * 1024 * 1024)
    if gb >= 1.0 { return String(format: "%.1f GB", gb) }
    let mb = Double(bytes) / (1024 * 1024)
    if mb >= 1.0 { return String(format: "%.1f MB", mb) }
    let kb = Double(bytes) / 1024
    if kb >= 1.0 { return String(format: "%.0f KB", kb) }
    return "\(bytes) B"
}

#Preview {
    AIStoragePanelView(model: AIStorageModel(previewSnapshot: .preview))
        .padding()
        .frame(width: 400)
}
