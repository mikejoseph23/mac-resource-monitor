import SwiftUI
import AppKit

/// "Let me actually read this log."
///
/// The read-only sibling of `AIStorageSearchSheet` and `AIStoragePurgeSheet`.
/// Search deliberately never shows matched text (the query *is* the secret);
/// this sheet is the opposite case — the user picked one specific file and
/// rendering its contents is the entire point.
///
/// Strictly read-only by construction: there is no delete, rename, move or
/// write affordance anywhere in this view, and the only thing it asks the model
/// for is a listing and a slice of bytes.
///
/// Shaped like a native log viewer rather than generic chrome: Finder's
/// source-list-and-detail split with sticky section headers on the left,
/// Console.app's dense monospaced tail on the right.
struct AIStorageLogsSheet: View {
    @ObservedObject var model: AIStorageModel
    @Environment(\.dismiss) private var dismiss

    /// Everything this sheet needs from the filesystem, behind four closures.
    /// See `AIStorageLogsSource` for why it isn't calling the model directly.
    private let source: AIStorageLogsSource

    init(model: AIStorageModel, source: AIStorageLogsSource? = nil) {
        self.model = model
        self.source = source ?? .live(model: model)
    }

    // MARK: - State

    @State private var targetID: String?
    @State private var entries: [AIStorageFileEntry] = []
    @State private var listPhase: ListPhase = .idle
    /// Bumped on every list request; a result carrying a stale generation is
    /// dropped. Switching targets quickly must not let an earlier, slower
    /// listing overwrite the newer one.
    @State private var listGeneration = 0

    @State private var selection: AIStorageFileEntry?
    @State private var content: AIStorageFileContent?
    @State private var isOpening = false
    @State private var isLoadingFull = false
    @State private var openGeneration = 0

    @State private var ageFilter: AgeFilter = .all
    @State private var jsonRendering: JSONRendering = .pretty

    /// The text actually on screen, and its line blocks, held in state rather
    /// than recomputed in `body`: after *Load full file* that is a 10 MB
    /// string, and re-splitting it on every SwiftUI pass would stutter the
    /// whole sheet.
    @State private var displayText = ""
    @State private var displayBlocks: [String] = []

    private enum ListPhase: Equatable {
        case idle, listing, listed
    }

    private enum AgeFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case month = "30 days"
        case week = "7 days"

        var id: String { rawValue }

        var days: Int? {
            switch self {
            case .all:   return nil
            case .month: return 30
            case .week:  return 7
            }
        }
    }

    private enum JSONRendering: String, CaseIterable, Identifiable {
        case raw = "Raw"
        case pretty = "Pretty"

        var id: String { rawValue }
    }

    // MARK: - Derived

    private var targets: [AIStorageTarget] {
        source.explorableTargets()
    }

    private var currentTarget: AIStorageTarget? {
        targets.first { $0.id == targetID }
    }

    /// The already newest-first listing, narrowed by the age filter. Filtering
    /// preserves order, so the sections below never need a re-sort.
    private var visibleEntries: [AIStorageFileEntry] {
        guard let days = ageFilter.days else { return entries }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return entries.filter { $0.modifiedAt >= cutoff }
    }

    /// `nil` section title means "this target isn't month-subdirectored", which
    /// collapses to a single unlabelled run of rows.
    private var sections: [(title: String?, entries: [AIStorageFileEntry])] {
        var result: [(String?, [AIStorageFileEntry])] = []
        for entry in visibleEntries {
            if var last = result.last, last.0 == entry.monthSection {
                last.1.append(entry)
                result[result.count - 1] = last
            } else {
                result.append((entry.monthSection, [entry]))
            }
        }
        return result.map { (title: $0.0, entries: $0.1) }
    }

    private var selectionIsJSON: Bool {
        guard let selection else { return false }
        return (selection.name as NSString).pathExtension.lowercased() == "json"
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            targetBar
            Divider()

            HStack(spacing: 0) {
                fileList
                    .frame(width: 280)
                Divider()
                viewer
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 520)

            Divider()
            footer
        }
        .frame(width: 820)
        .task {
            if targetID == nil, let first = targets.first {
                targetID = first.id
                await list(targetID: first.id)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
            Text("Explore Logs")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("read-only")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color.primary.opacity(0.06))
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The target picker plus the panel's refresh affordance, carried over so a
    /// re-list looks like the same gesture as a rescan.
    private var targetBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(
                get: { targetID ?? targets.first?.id ?? "" },
                set: { newID in
                    guard newID != targetID else { return }
                    targetID = newID
                    Task { await list(targetID: newID) }
                }
            )) {
                ForEach(targets) { target in
                    Text(target.label).tag(target.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(targets.isEmpty)

            if let target = currentTarget {
                Text(target.displayPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button {
                if let targetID { Task { await list(targetID: targetID) } }
            } label: {
                if listPhase == .listing {
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
            .foregroundStyle(.tertiary)
            .disabled(listPhase == .listing || targetID == nil)
            .help("Re-list files in this location")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - File list

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Picker("", selection: $ageFilter) {
                    ForEach(AgeFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch listPhase {
                case .idle, .listing:
                    listPlaceholder(
                        icon: "clock",
                        title: listPhase == .listing ? "Listing files…" : "Nothing listed yet",
                        detail: nil,
                        showsSpinner: listPhase == .listing
                    )
                case .listed:
                    if entries.isEmpty {
                        listPlaceholder(
                            icon: "tray",
                            title: "No files here",
                            detail: currentTarget.map { "\($0.displayPath) is empty." },
                            showsSpinner: false
                        )
                    } else if visibleEntries.isEmpty {
                        listPlaceholder(
                            icon: "calendar.badge.exclamationmark",
                            title: "Nothing in the last \(ageFilter.days ?? 0) days",
                            detail: "\(entries.count) older file\(entries.count == 1 ? "" : "s") hidden by the filter.",
                            showsSpinner: false,
                            action: ("Show all", { ageFilter = .all })
                        )
                    } else {
                        rows
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.primary.opacity(0.025))
    }

    /// `LazyVStack` is load-bearing, not stylistic: `server-logs` is ~3080
    /// files on the machine this was built for, and an eager stack renders all
    /// of them on every target switch.
    private var rows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Section {
                        ForEach(section.entries) { entry in
                            fileRow(entry)
                        }
                    } header: {
                        if let title = section.title {
                            sectionHeader(title, entries: section.entries)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .animation(.easeInOut(duration: 0.16), value: ageFilter)
    }

    private func sectionHeader(_ title: String, entries: [AIStorageFileEntry]) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("\(entries.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func fileRow(_ entry: AIStorageFileEntry) -> some View {
        let isSelected = selection?.id == entry.id
        // Server logs repeat the filename inside `relativePath`; showing both
        // would be noise, so the second line falls back to the timestamp.
        let subtitle = entry.relativePath == entry.name
            ? shortTimestamp(entry.modifiedAt)
            : entry.relativePath

        return Button {
            select(entry)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(aiStorageFormatBytes(entry.sizeBytes))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.accentColor)
                        .frame(width: 2)
                        .padding(.vertical, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.top, 1)
        .help(entry.displayPath)
    }

    private func listPlaceholder(icon: String,
                                 title: String,
                                 detail: String?,
                                 showsSpinner: Bool,
                                 action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 6) {
            if showsSpinner {
                ProgressView().controlSize(.small).scaleEffect(0.8)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.quaternary)
            }
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action.0) { action.1() }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Viewer

    @ViewBuilder
    private var viewer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selection {
                viewerToolbar(selection)
                Divider()
            }

            Group {
                if selection == nil {
                    viewerPlaceholder(
                        icon: "doc.text",
                        title: "Select a file to read it",
                        detail: "Files open at the end, the way a log is usually read."
                    )
                } else if isOpening {
                    viewerPlaceholder(icon: "clock", title: "Opening…", detail: nil, showsSpinner: true)
                } else if let content {
                    contentBody(content)
                } else {
                    viewerPlaceholder(
                        icon: "questionmark.folder",
                        title: "Couldn't read that file",
                        detail: nil
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: jsonRendering) { refreshDisplayText() }
    }

    private func viewerToolbar(_ entry: AIStorageFileEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(aiStorageFormatBytes(entry.sizeBytes)) · \(shortTimestamp(entry.modifiedAt))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            if selectionIsJSON, content?.state == .ok, !(content?.looksBinary ?? false) {
                Picker("", selection: $jsonRendering) {
                    ForEach(JSONRendering.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func contentBody(_ content: AIStorageFileContent) -> some View {
        switch content.state {
        case .missing:
            viewerPlaceholder(
                icon: "exclamationmark.triangle",
                title: "This file no longer exists",
                detail: "It was probably rotated or purged since the list was built.",
                action: ("Re-list files", { if let targetID { Task { await list(targetID: targetID) } } })
            )
        case .denied:
            viewerPlaceholder(
                icon: "lock",
                title: "macOS wouldn't allow reading this file",
                detail: content.displayPath
            )
        case .ok:
            if content.looksBinary {
                viewerPlaceholder(
                    icon: "square.grid.3x3.fill",
                    title: "Not a text file",
                    detail: "\(aiStorageFormatBytes(content.totalBytes)) of binary data — rendering it as text would be meaningless.",
                    action: selection.map { entry in
                        ("Reveal in Finder", {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                        })
                    }
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if content.isTruncated {
                        truncationBanner(content)
                        Divider()
                    } else if selectionIsJSON, jsonRendering == .pretty, displayText == content.text {
                        notice(
                            icon: "curlybraces",
                            text: "Not parseable as JSON — showing the raw text.",
                            tint: .secondary
                        )
                        Divider()
                    }
                    logText
                }
            }
        }
    }

    private func truncationBanner(_ content: AIStorageFileContent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text("Showing the last \(aiStorageFormatBytes(UInt64(content.text.utf8.count))) of \(aiStorageFormatBytes(content.totalBytes)).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if isLoadingFull {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            Button("Load full file") { loadFull() }
                .controlSize(.small)
                .disabled(isLoadingFull)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09))
    }

    private func notice(icon: String, text: String, tint: HierarchicalShapeStyle) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
    }

    /// Console.app's reading experience: dense monospaced rows, tail-anchored.
    ///
    /// Split into blocks rather than one giant `Text` because *Load full file*
    /// on a rotated 10 MB log would otherwise ask TextKit to lay out ten
    /// million characters in one pass. Blocks are large enough (400 lines) that
    /// ordinary selection and copy still work within a screenful.
    private var logText: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayBlocks.enumerated()), id: \.offset) { index, block in
                        Text(block)
                            .font(.system(size: 11, design: .monospaced))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(index)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(logBottomAnchor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                // A log is read from the end. Jump without animating: an
                // animated scroll through a 10 MB tail is a visible stutter.
                proxy.scrollTo(logBottomAnchor, anchor: .bottom)
            }
            .onChange(of: displayText) {
                proxy.scrollTo(logBottomAnchor, anchor: .bottom)
            }
        }
    }

    private func viewerPlaceholder(icon: String,
                                   title: String,
                                   detail: String?,
                                   showsSpinner: Bool = false,
                                   action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 8) {
            if showsSpinner {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.quaternary)
            }
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action {
                Button(action.0) { action.1() }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(selection?.displayPath ?? "Nothing here deletes or modifies a file.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    /// Guarded against duplicate in-flight listings: the generation stamp means
    /// a slow listing for an abandoned target can never land on top of a newer
    /// one, and the re-list button is disabled while one is running.
    private func list(targetID id: String) async {
        listGeneration += 1
        let generation = listGeneration

        withAnimation(.easeInOut(duration: 0.16)) {
            listPhase = .listing
            entries = []
            selection = nil
            content = nil
        }
        refreshDisplayText()

        let listed = await source.listFiles(id)
        guard generation == listGeneration else { return }

        withAnimation(.easeInOut(duration: 0.16)) {
            entries = listed
            listPhase = .listed
        }

        // Open the newest file straight away — "what did it just log?" is the
        // question this browser exists to answer.
        if let newest = visibleEntries.first ?? listed.first {
            select(newest)
        }
    }

    private func select(_ entry: AIStorageFileEntry) {
        guard selection?.id != entry.id || content == nil else { return }
        selection = entry
        content = nil
        jsonRendering = .pretty
        refreshDisplayText()
        openGeneration += 1
        let generation = openGeneration
        isOpening = true

        Task {
            let opened = await source.open(entry)
            guard generation == openGeneration else { return }
            isOpening = false
            withAnimation(.easeInOut(duration: 0.14)) {
                content = opened
            }
            refreshDisplayText()
        }
    }

    private func loadFull() {
        guard let entry = selection, !isLoadingFull else { return }
        isLoadingFull = true
        openGeneration += 1
        let generation = openGeneration

        Task {
            let full = await source.loadFull(entry)
            guard generation == openGeneration else { return }
            isLoadingFull = false
            content = full
            refreshDisplayText()
        }
    }

    // MARK: - Text rendering

    /// Recomputes the on-screen text (and its blocks) from the current content
    /// and raw/pretty choice. The one place that decides what the viewer shows.
    private func refreshDisplayText() {
        guard let content, content.state == .ok, !content.looksBinary else {
            displayText = ""
            displayBlocks = []
            return
        }
        let text = (selectionIsJSON && jsonRendering == .pretty)
            ? (prettyJSON(content.text) ?? content.text)
            : content.text
        displayText = text
        displayBlocks = textBlocks(text)
    }

    /// A tail slice of a JSON file is not valid JSON, so this quietly fails and
    /// the raw text is shown instead — with a one-line notice above it.
    private func prettyJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .withoutEscapingSlashes]
              )
        else { return nil }
        return String(decoding: pretty, as: UTF8.self)
    }

    private func textBlocks(_ text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > logBlockLines else { return [text] }
        return stride(from: 0, to: lines.count, by: logBlockLines).map { start in
            lines[start..<min(start + logBlockLines, lines.count)].joined(separator: "\n")
        }
    }

    private func shortTimestamp(_ date: Date) -> String {
        Self.timestampFormatter.string(from: date)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private let logBlockLines = 400
    private let logBottomAnchor = "ai-storage-log-bottom"
}

// MARK: - Filesystem source

/// Everything `AIStorageLogsSheet` needs from disk, as four closures.
///
/// Indirection rather than calling `AIStorageModel` inline for two reasons:
/// the previews need to render every state (populated, tail-truncated, binary,
/// missing) without a real home directory behind them, and the sheet stays
/// honest about its own surface area — four read operations, no writes.
struct AIStorageLogsSource {
    var explorableTargets: @MainActor () -> [AIStorageTarget]
    var listFiles: @MainActor (String) async -> [AIStorageFileEntry]
    var open: @MainActor (AIStorageFileEntry) async -> AIStorageFileContent
    var loadFull: @MainActor (AIStorageFileEntry) async -> AIStorageFileContent
}

// MARK: - M2 bridge (STUB — replace the marked bodies with the real calls)
//
// The real filesystem wrappers (`AIStorageModel.listFiles(targetID:)`,
// `.open(entry:)`, `.loadFull(entry:)`) land with Milestone 2. Until then this
// bridge answers with empty listings so the UI builds and runs. Swapping it is
// a three-line change; see the comment on each line.

extension AIStorageLogsSource {
    static func live(model: AIStorageModel) -> AIStorageLogsSource {
        AIStorageLogsSource(
            explorableTargets: { model.snapshot?.explorableTargets.filter(\.exists) ?? [] },
            // M2: await model.listFiles(targetID: id)
            listFiles: { _ in [] },
            // M2: await model.open(entry: entry)
            open: { entry in .missing(displayPath: entry.displayPath) },
            // M2: await model.loadFull(entry: entry)
            loadFull: { entry in .missing(displayPath: entry.displayPath) }
        )
    }
}

/// One file's readable contents, as handed to the viewer.
///
/// STUB — Milestone 2 owns the real definition (it is what
/// `AIStorageCollector.open(entry:)` returns). Delete this declaration when M2
/// lands; the viewer only touches `state`, `text`, `totalBytes`, `isTruncated`,
/// `displayPath` and `looksBinary`.
struct AIStorageFileContent: Equatable {
    enum State: Equatable {
        /// Read succeeded — `text` holds the whole file or its tail.
        case ok
        /// The path failed `AIStoragePathGuard.isReadable`, or macOS refused it.
        case denied
        /// Rotated or purged between the listing and the open.
        case missing
    }

    let state: State
    /// The file's text, or its tail when `isTruncated`. Lossy UTF-8.
    let text: String
    /// Size of the whole file on disk, not of `text`.
    let totalBytes: UInt64
    /// True when `text` is only the tail.
    let isTruncated: Bool
    let displayPath: String
    let looksBinary: Bool

    static func missing(displayPath: String) -> AIStorageFileContent {
        AIStorageFileContent(state: .missing, text: "", totalBytes: 0,
                             isTruncated: false, displayPath: displayPath, looksBinary: false)
    }
}

// MARK: - Previews

#if DEBUG
extension AIStorageLogsSource {
    /// Fixture source backed by `AIStorageSnapshot.previewFileEntries`, so every
    /// viewer state is renderable without a home directory.
    static func preview(entries: [AIStorageFileEntry] = AIStorageSnapshot.previewFileEntries,
                        targets: [AIStorageTarget] = AIStorageSnapshot.preview.explorableTargets) -> AIStorageLogsSource {
        AIStorageLogsSource(
            explorableTargets: { targets },
            listFiles: { id in
                switch id {
                case "lmstudio.server-logs":   return entries.filter { $0.monthSection != nil }
                case "lmstudio.conversations": return entries.filter { $0.name.hasSuffix(".json") }
                default:                       return []
                }
            },
            open: { entry in previewContent(for: entry, full: false) },
            loadFull: { entry in previewContent(for: entry, full: true) }
        )
    }

    private static func previewContent(for entry: AIStorageFileEntry, full: Bool) -> AIStorageFileContent {
        if entry.looksBinary {
            return AIStorageFileContent(state: .ok, text: "", totalBytes: entry.sizeBytes,
                                        isTruncated: false, displayPath: entry.displayPath,
                                        looksBinary: true)
        }
        if entry.name.hasSuffix(".json") {
            let json = #"{"id":"1784921389195","title":"Quantisation trade-offs","messages":[{"role":"user","content":"How much does Q4_K_M cost me on a 70B?"},{"role":"assistant","content":"Roughly 40 GB resident, versus 140 GB at fp16."}],"model":"qwen3-coder-30b"}"#
            return AIStorageFileContent(state: .ok, text: json, totalBytes: entry.sizeBytes,
                                        isTruncated: false, displayPath: entry.displayPath,
                                        looksBinary: false)
        }
        let truncated = !full && entry.sizeBytes > 262_144
        var lines: [String] = []
        for index in 0..<80 {
            let stamp = String(format: "2026-08-22 17:%02d:%02d", index / 4, (index * 7) % 60)
            switch index % 4 {
            case 0: lines.append("\(stamp)  [INFO]  [LM STUDIO SERVER] Running chat completion on conversation with 12 messages.")
            case 1: lines.append("\(stamp)  [INFO]  [LM STUDIO SERVER] Accumulating tokens … (stream = true)")
            case 2: lines.append("\(stamp)  [INFO]  [LM STUDIO SERVER] First token generated. Continuing to stream response…")
            default: lines.append("\(stamp)  [INFO]  [LM STUDIO SERVER] Generated prediction: 618 tokens in 4.21s (146.8 tok/s)")
            }
        }
        return AIStorageFileContent(state: .ok, text: lines.joined(separator: "\n"),
                                    totalBytes: entry.sizeBytes, isTruncated: truncated,
                                    displayPath: entry.displayPath, looksBinary: false)
    }
}

#Preview("Populated + tail banner") {
    AIStorageLogsSheet(model: AIStorageModel(previewSnapshot: .preview),
                       source: .preview())
}

#Preview("Empty target") {
    AIStorageLogsSheet(model: AIStorageModel(previewSnapshot: .preview),
                       source: .preview(entries: []))
}
#endif
