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
    @State private var showingChats = false

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
        .contextMenu { actionMenuItems }
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
        .sheet(isPresented: $showingChats) {
            AIStorageChatsSheet(model: model)
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

            actionMenu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Every action this panel offers, behind one glyph.
    ///
    /// Four buttons in a row wrapped badly at the narrow layout, and three of
    /// them open read-only sheets that are browsed occasionally rather than a
    /// primary gesture — so they live here, with Purge divided off and marked
    /// destructive rather than sitting a pointer-width from "Explore chats…".
    /// The same items are on the card's right-click menu.
    private var actionMenu: some View {
        Menu {
            actionMenuItems
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.tertiary)
        .disabled(model.snapshot == nil)
        .help("Search, explore or purge retained data")
    }

    @ViewBuilder
    private var actionMenuItems: some View {
        Button("Search retained text…") { showingSearch = true }
        Button("Explore logs…") { showingExplore = true }
            .disabled(model.snapshot?.containsExplorable != true)
        Button("Explore chats…") { showingChats = true }
            .disabled(!model.hasConversations)
        Divider()
        Button("Purge…", role: .destructive) { showingPurge = true }
            .disabled(model.snapshot == nil)
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

    /// Four actions is one more than this row comfortably fits when the panel
    /// is sharing the bottom region side-by-side, so it falls back to two rows
    /// rather than truncating a button label. Wide layouts are unchanged.
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

#if DEBUG
#Preview {
    AIStoragePanelView(model: AIStorageModel(previewSnapshot: .preview))
        .padding()
        .frame(width: 400)
}
#endif
