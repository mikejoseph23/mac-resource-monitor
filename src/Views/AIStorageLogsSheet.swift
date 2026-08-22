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
    @Environment(\.colorScheme) private var colorScheme

    /// Non-monospaced labels track the user's text-size setting; the log body
    /// tracks it too but clamped (see `monoFont`).
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

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
    /// The in-flight listing, held so it can be cancelled when the target
    /// changes or the sheet goes away — a ~3000-file walk must not outlive the
    /// window that asked for it.
    @State private var listTask: Task<Void, Never>?

    @State private var selection: AIStorageFileEntry?
    /// Keyboard cursor, deliberately separate from `selection`: arrow keys move
    /// this highlight without reading a file, Return opens what it points at.
    @State private var cursor: AIStorageFileEntry?
    @State private var content: AIStorageFileContent?
    @State private var isOpening = false
    @State private var isLoadingEarlier = false
    @State private var openGeneration = 0
    @State private var openTask: Task<Void, Never>?

    @State private var ageFilter: AgeFilter = .all
    @State private var jsonRendering: JSONRendering = .pretty

    /// The loaded byte windows of the current file, oldest first. The viewer
    /// pages backwards through a file rather than reading it whole, so this is
    /// normally the tail plus whatever the user scrolled back into.
    @State private var chunks: [LogChunk] = []
    /// Byte offset of the first loaded byte. `> 0` means there is older content
    /// above, which is what the truncation banner and the paging trigger key off.
    @State private var windowStart = 0

    /// The text actually on screen, and its line blocks, held in state rather
    /// than recomputed in `body`: after paging the whole way back that is a
    /// 10 MB string, and re-splitting it on every SwiftUI pass would stutter
    /// the whole sheet.
    @State private var displayText = ""
    @State private var displayBlocks: [LogBlock] = []
    /// Set when pretty-printing was asked for but the loaded text isn't valid
    /// JSON (a partial window never is) — drives the one-line notice.
    @State private var jsonFallback = false

    /// Bumped whenever `displayBlocks` changes, so the scroll effect fires once
    /// per content change and applies `pendingScroll`.
    @State private var displayRevision = 0
    @State private var pendingScroll: ScrollIntent = .none
    /// Auto-paging stays off until the initial jump-to-bottom has settled,
    /// otherwise the top sentinel's first appearance would immediately page in
    /// content the user never scrolled to.
    @State private var pagingArmed = false

    @FocusState private var listFocused: Bool
    @State private var watcher = AIStorageDirectoryWatcher()

    private enum ListPhase: Equatable {
        case idle, listing, listed
    }

    /// What the viewer should do the next time its content changes: jump to the
    /// end (a freshly opened log is read from the bottom) or hold the user's
    /// reading position at a known block (content was added above them).
    private enum ScrollIntent: Equatable {
        case none
        case bottom
        case keep(blockID: String)
    }

    /// One loaded byte window. Split into blocks per chunk so that paging in
    /// older content never renumbers the blocks already on screen — that
    /// stability is what makes "hold the reading position" possible.
    private struct LogChunk: Identifiable {
        let id: Int
        let startOffset: Int
        let text: String
    }

    private struct LogBlock: Identifiable {
        let id: String
        let text: String
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

    private var loadedBytes: Int {
        chunks.reduce(0) { $0 + $1.text.utf8.count }
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
                startList(targetID: first.id)
            }
        }
        .onDisappear {
            // Nothing survives the sheet: no orphaned directory walk, no
            // orphaned read, no file descriptor left watching a directory.
            listTask?.cancel()
            listTask = nil
            openTask?.cancel()
            openTask = nil
            watcher.stop()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
            Text("Explore Logs")
                .font(uiFont(13, weight: .semibold))
            Spacer()
            Text("read-only")
                .font(uiFont(10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07))
                )
                .accessibilityLabel("This browser is read-only")
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
                    startList(targetID: newID)
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
            .accessibilityLabel("Location")

            if let target = currentTarget {
                Text(target.displayPath)
                    .font(monoFont(10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Folder \(target.displayPath)")
            }

            Spacer(minLength: 8)

            Button {
                if let targetID { startList(targetID: targetID) }
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
            .foregroundStyle(.secondary)
            .disabled(listPhase == .listing || targetID == nil)
            .help("Re-list files in this location")
            .accessibilityLabel("Re-list files")
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
                .accessibilityLabel("Age filter")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            Group {
                switch listPhase {
                case .idle, .listing:
                    if entries.isEmpty {
                        listPlaceholder(
                            icon: "clock",
                            title: listPhase == .listing ? "Listing files…" : "Nothing listed yet",
                            detail: nil,
                            showsSpinner: listPhase == .listing
                        )
                    } else {
                        // A background re-list (the directory changed on disk)
                        // keeps the current rows on screen rather than blanking
                        // the list under the user.
                        rows
                    }
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
        .background(sidebarBackground)
    }

    /// `LazyVStack` is load-bearing, not stylistic: `server-logs` is ~3080
    /// files on the machine this was built for, and an eager stack renders all
    /// of them on every target switch.
    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        Section {
                            ForEach(section.entries) { entry in
                                fileRow(entry)
                                    .id(entry.id)
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
            // Keyboard navigation: arrows move the cursor, Return opens it.
            .focusable()
            .focused($listFocused)
            .onMoveCommand { direction in moveCursor(direction, proxy: proxy) }
            .onKeyPress(.return) {
                guard let cursor else { return .ignored }
                select(cursor)
                return .handled
            }
            .accessibilityLabel("Files")
        }
    }

    private func sectionHeader(_ title: String, entries: [AIStorageFileEntry]) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(monoFont(10, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Text("\(entries.count)")
                .font(monoFont(10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(entries.count) file\(entries.count == 1 ? "" : "s")")
        .accessibilityAddTraits(.isHeader)
    }

    private func fileRow(_ entry: AIStorageFileEntry) -> some View {
        let isSelected = selection?.id == entry.id
        let isCursor = cursor?.id == entry.id
        // Server logs repeat the filename inside `relativePath`; showing both
        // would be noise, so the second line falls back to the timestamp.
        let subtitle = entry.relativePath == entry.name
            ? shortTimestamp(entry.modifiedAt)
            : entry.relativePath

        return Button {
            cursor = entry
            listFocused = true
            select(entry)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.name)
                        .font(uiFont(12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(aiStorageFormatBytes(entry.sizeBytes))
                        .font(monoFont(10))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
                Text(subtitle)
                    .font(monoFont(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(selectionWashOpacity) : Color.clear)
            }
            .overlay {
                // The keyboard cursor is a ring, so it stays distinguishable
                // from the opened file's wash when they're on different rows.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isCursor ? 0.85 : 0), lineWidth: 1.5)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name), \(aiStorageFormatBytes(entry.sizeBytes)), modified \(accessibleTimestamp(entry.modifiedAt))")
        .accessibilityHint("Opens this file in the viewer")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
                    .foregroundStyle(placeholderGlyph)
            }
            Text(title)
                .font(uiFont(11, weight: .medium))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(uiFont(10))
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
                    .font(uiFont(12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(aiStorageFormatBytes(entry.sizeBytes)) · \(shortTimestamp(entry.modifiedAt))")
                    .font(monoFont(10))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Viewing \(entry.name), \(aiStorageFormatBytes(entry.sizeBytes)), modified \(accessibleTimestamp(entry.modifiedAt))")

            Spacer(minLength: 8)

            if selectionIsJSON, content?.access == .ok, !(content?.looksBinary ?? false) {
                Picker("", selection: $jsonRendering) {
                    ForEach(JSONRendering.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("JSON rendering")
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
            .accessibilityLabel("Reveal in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func contentBody(_ content: AIStorageFileContent) -> some View {
        switch content.access {
        case .missingFile:
            viewerPlaceholder(
                icon: "exclamationmark.triangle",
                title: "This file no longer exists",
                detail: "It was probably rotated or purged since the list was built.",
                action: ("Re-list files", { if let targetID { startList(targetID: targetID) } })
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
                    detail: "\(aiStorageFormatBytes(UInt64(max(0, content.totalBytes)))) of binary data — rendering it as text would be meaningless.",
                    action: selection.map { entry in
                        ("Reveal in Finder", {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                        })
                    }
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if windowStart > 0 {
                        truncationBanner(content)
                        Divider()
                    } else if selectionIsJSON, jsonRendering == .pretty, jsonFallback {
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
            Text("Showing the last \(aiStorageFormatBytes(UInt64(loadedBytes))) of \(aiStorageFormatBytes(UInt64(max(0, content.totalBytes)))). Scroll up for more.")
                .font(uiFont(11))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if isLoadingEarlier {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            Button("Load full file") { loadEarlier(limit: windowStart) }
                .controlSize(.small)
                .disabled(isLoadingEarlier)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(colorScheme == .dark ? 0.20 : 0.10))
    }

    private func notice(icon: String, text: String, tint: HierarchicalShapeStyle) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(tint)
            Text(text)
                .font(uiFont(11))
                .foregroundStyle(tint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04))
    }

    /// Console.app's reading experience: dense monospaced rows, tail-anchored.
    ///
    /// Split into blocks rather than one giant `Text` because paging all the way
    /// back through a rotated 10 MB log would otherwise ask TextKit to lay out
    /// ten million characters in one pass. Blocks are large enough (400 lines)
    /// that ordinary selection and copy still work within a screenful.
    private var logText: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if windowStart > 0 {
                        // Reaching this sentinel *is* the paging trigger; the
                        // button is the same action for people who'd rather
                        // click (and for VoiceOver users, who never "scroll").
                        loadEarlierRow
                            .onAppear {
                                guard pagingArmed else { return }
                                loadEarlier(limit: pageBytes)
                            }
                    }
                    ForEach(displayBlocks) { block in
                        Text(block.text)
                            .font(monoFont(11))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(block.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(logBottomAnchor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityLabel(selection.map { "Contents of \($0.name)" } ?? "Log contents")
            .onAppear {
                // A log is read from the end. Jump without animating: an
                // animated scroll through a 10 MB tail is a visible stutter.
                proxy.scrollTo(logBottomAnchor, anchor: .bottom)
                armPaging()
            }
            .onChange(of: displayRevision) {
                applyPendingScroll(proxy)
            }
        }
    }

    /// The top-of-file affordance: what the user reaches by scrolling up.
    private var loadEarlierRow: some View {
        HStack(spacing: 8) {
            if isLoadingEarlier {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text("Loading earlier lines…")
                    .font(uiFont(10))
                    .foregroundStyle(.secondary)
            } else {
                Button("Load earlier lines") { loadEarlier(limit: pageBytes) }
                    .controlSize(.small)
                Text("\(aiStorageFormatBytes(UInt64(max(0, windowStart)))) above this point")
                    .font(uiFont(10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .foregroundStyle(placeholderGlyph)
            }
            Text(title)
                .font(uiFont(12, weight: .medium))
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(uiFont(11))
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
                .foregroundStyle(.secondary)
            Text(selection?.displayPath ?? "Nothing here deletes or modifies a file.")
                .font(monoFont(10))
                .foregroundStyle(.secondary)
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

    // MARK: - Appearance

    /// Light and dark need different weights of the same idea: a faint wash of
    /// the foreground colour reads as a recessed sidebar in light, and needs
    /// roughly double the opacity to read at all in dark.
    private var sidebarBackground: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.03)
    }

    private var selectionWashOpacity: Double {
        colorScheme == .dark ? 0.28 : 0.16
    }

    /// `.quaternary` disappears against a dark background; the placeholder
    /// glyphs step up one level there.
    private var placeholderGlyph: HierarchicalShapeStyle {
        colorScheme == .dark ? .tertiary : .quaternary
    }

    private func uiFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * typeScale, weight: weight)
    }

    /// Monospaced text scales too, but within bounds: never below its design
    /// size (dense log columns stop being readable) and never more than a few
    /// points above it (the 400-line blocks are laid out eagerly, and unbounded
    /// growth makes them enormous).
    private func monoFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: min(max(size * typeScale, size), size + 6), weight: weight, design: .monospaced)
    }

    // MARK: - Actions

    /// Starts (or restarts) a listing, cancelling whatever walk was in flight.
    /// `preservingSelection` is the on-disk-changed path: re-list underneath the
    /// user without blanking the list or yanking the file they're reading.
    private func startList(targetID id: String, preservingSelection: Bool = false) {
        listTask?.cancel()
        listTask = Task { await list(targetID: id, preservingSelection: preservingSelection) }
    }

    /// Guarded against duplicate in-flight listings: the generation stamp means
    /// a slow listing for an abandoned target can never land on top of a newer
    /// one, and the re-list button is disabled while one is running.
    private func list(targetID id: String, preservingSelection: Bool) async {
        listGeneration += 1
        let generation = listGeneration
        let keepID = preservingSelection ? selection?.id : nil

        if preservingSelection {
            listPhase = .listing
        } else {
            withAnimation(.easeInOut(duration: 0.16)) {
                listPhase = .listing
                entries = []
                selection = nil
                cursor = nil
                content = nil
            }
            resetWindow()
        }

        let listed = await source.listFiles(id)
        // Two guards, not one: the generation catches a superseded listing, and
        // `isCancelled` catches a sheet that went away mid-walk.
        guard generation == listGeneration, !Task.isCancelled else { return }

        withAnimation(.easeInOut(duration: 0.16)) {
            entries = listed
            listPhase = .listed
        }
        watchCurrentDirectories()

        if let keepID {
            if let stillThere = listed.first(where: { $0.id == keepID }) {
                // The file the user is reading survived the change on disk:
                // leave it, and its scroll position, exactly where it was.
                selection = stillThere
                cursor = stillThere
                return
            }
            // It didn't survive — fall through and open the newest instead,
            // which is the "my log just rotated" case.
        }

        // Open the newest file straight away — "what did it just log?" is the
        // question this browser exists to answer.
        if let newest = visibleEntries.first ?? listed.first {
            cursor = newest
            select(newest)
        }
    }

    private func select(_ entry: AIStorageFileEntry) {
        guard selection?.id != entry.id || content == nil else { return }
        selection = entry
        content = nil
        jsonRendering = .pretty
        resetWindow()
        openGeneration += 1
        let generation = openGeneration
        isOpening = true

        openTask?.cancel()
        openTask = Task {
            let opened = await source.open(entry)
            guard generation == openGeneration, !Task.isCancelled else { return }
            isOpening = false
            withAnimation(.easeInOut(duration: 0.14)) {
                content = opened
            }
            if opened.access == .ok, !opened.looksBinary {
                chunks = [LogChunk(id: nextChunkID(), startOffset: opened.startOffset, text: opened.text)]
                windowStart = opened.startOffset
            }
            // A newly opened log lands at its end; that's the one time the
            // viewer is allowed to move the user itself.
            pendingScroll = .bottom
            pagingArmed = false
            refreshDisplayText()
            armPaging()
        }
    }

    /// Pages in the `limit` bytes above what's loaded, keeping the user's
    /// reading position pinned to the block they were on. `limit == windowStart`
    /// is the *Load full file* case — same code path, bigger bite.
    private func loadEarlier(limit: Int) {
        guard let entry = selection, !isLoadingEarlier, windowStart > 0, limit > 0 else { return }
        isLoadingEarlier = true
        let generation = openGeneration
        let anchorID = displayBlocks.first?.id
        let end = windowStart

        Task {
            let earlier = await source.loadEarlier(entry, end, limit)
            guard generation == openGeneration, !Task.isCancelled else { return }
            isLoadingEarlier = false
            guard earlier.access == .ok, !earlier.text.isEmpty else {
                // Vanished or refused mid-read: surface it the same way an open
                // would, rather than silently leaving a dead "load more" row.
                if earlier.access != .ok { content = earlier }
                return
            }
            chunks.insert(LogChunk(id: nextChunkID(), startOffset: earlier.startOffset, text: earlier.text), at: 0)
            windowStart = earlier.startOffset
            pendingScroll = anchorID.map { .keep(blockID: $0) } ?? .none
            // The sentinel is re-created above the restored anchor and may land
            // inside the lazy render window straight away; disarming across the
            // prepend stops one scroll gesture from cascading into several
            // pages. Scrolling up again re-appears it and pages once more.
            pagingArmed = false
            refreshDisplayText()
            armPaging()
        }
    }

    private func moveCursor(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        let list = visibleEntries
        guard !list.isEmpty else { return }
        let current = cursor.flatMap { candidate in list.firstIndex(where: { $0.id == candidate.id }) }

        let target: Int
        switch direction {
        case .up:   target = (current ?? 0) - 1
        case .down: target = (current ?? -1) + 1
        default:    return
        }

        let clamped = min(max(target, 0), list.count - 1)
        cursor = list[clamped]
        proxy.scrollTo(list[clamped].id, anchor: .center)
    }

    private func resetWindow() {
        chunks = []
        windowStart = 0
        isLoadingEarlier = false
        pagingArmed = false
        refreshDisplayText()
    }

    private func nextChunkID() -> Int {
        chunkSequence += 1
        return chunkSequence
    }

    /// The paging trigger stays disarmed until after the opening jump to the
    /// bottom, so the sentinel appearing during initial layout doesn't count as
    /// "the user scrolled to the top".
    private func armPaging() {
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            pagingArmed = true
        }
    }

    private func applyPendingScroll(_ proxy: ScrollViewProxy) {
        let intent = pendingScroll
        pendingScroll = .none
        switch intent {
        case .none:
            break
        case .bottom:
            proxy.scrollTo(logBottomAnchor, anchor: .bottom)
        case .keep(let blockID):
            // One runloop hop: the prepended blocks have to exist in the layout
            // before the proxy can put the anchor back under the user's eyes.
            DispatchQueue.main.async {
                proxy.scrollTo(blockID, anchor: .top)
            }
        }
    }

    // MARK: - On-disk changes

    /// Re-list when the target's directory changes underneath the browser — a
    /// log rotating, a conversation being deleted from LM Studio. Read-only:
    /// the watcher opens the directories `O_EVTONLY` and never writes.
    ///
    /// Watches the target root plus the directory holding the newest entry, so
    /// the month-subdirectored `server-logs` layout (`2026-08/…`) is covered
    /// without walking a watch onto ~3000 files.
    private func watchCurrentDirectories() {
        guard let target = currentTarget else {
            watcher.stop()
            return
        }
        var paths = [target.path]
        if let newest = entries.first {
            let parent = (newest.path as NSString).deletingLastPathComponent
            if parent != target.path { paths.append(parent) }
        }
        watcher.watch(paths: paths) {
            Task { @MainActor in
                guard let targetID, listPhase != .listing else { return }
                startList(targetID: targetID, preservingSelection: true)
            }
        }
    }

    // MARK: - Text rendering

    /// Recomputes the on-screen text (and its blocks) from the loaded windows
    /// and the raw/pretty choice. The one place that decides what the viewer
    /// shows — and the only place `displayRevision` is bumped.
    private func refreshDisplayText() {
        defer { displayRevision += 1 }

        guard let content, content.access == .ok, !content.looksBinary else {
            displayText = ""
            displayBlocks = []
            jsonFallback = false
            return
        }

        let joined = chunks.map(\.text).joined()

        // Pretty-printing only makes sense for a whole file in hand; a window
        // of a JSON file is never valid JSON, so the notice explains the raw
        // fallback instead of pretending the parse failed for another reason.
        if selectionIsJSON, jsonRendering == .pretty {
            if windowStart == 0, chunks.count <= 1, let pretty = prettyJSON(joined) {
                displayText = pretty
                displayBlocks = blocks(for: pretty, chunkID: prettyChunkID)
                jsonFallback = false
                return
            }
            jsonFallback = true
        } else {
            jsonFallback = false
        }

        displayText = joined
        displayBlocks = chunks.flatMap { blocks(for: $0.text, chunkID: $0.id) }
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

    /// Splits one chunk into 400-line blocks. Ids are chunk-scoped so that
    /// prepending a chunk leaves every existing block's id untouched — the
    /// scroll anchor depends on that.
    private func blocks(for text: String, chunkID: Int) -> [LogBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > logBlockLines else {
            return [LogBlock(id: "\(chunkID).0", text: text)]
        }
        return stride(from: 0, to: lines.count, by: logBlockLines).map { start in
            LogBlock(
                id: "\(chunkID).\(start)",
                text: lines[start..<min(start + logBlockLines, lines.count)].joined(separator: "\n")
            )
        }
    }

    private func shortTimestamp(_ date: Date) -> String {
        Self.timestampFormatter.string(from: date)
    }

    /// Spoken form: "22 August 2026 at 17:04" reads far better than the packed
    /// `yyyy-MM-dd HH:mm` the rows show.
    private func accessibleTimestamp(_ date: Date) -> String {
        Self.accessibleFormatter.string(from: date)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let accessibleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    @State private var chunkSequence = 0

    private let logBlockLines = 400
    private let logBottomAnchor = "ai-storage-log-bottom"
    private let prettyChunkID = -1
    /// One page of scroll-back. Matches the collector's default tail budget, so
    /// paging up feels like "one more screenful of the same size".
    private let pageBytes = 256 * 1024
}

// MARK: - Directory watching

/// Watches directories for content changes so the log browser can re-list when
/// a file rotates or is deleted underneath it.
///
/// Read-only by construction: the descriptors are opened `O_EVTONLY`, which
/// grants no read or write access to the contents at all — it only permits
/// event delivery.
final class AIStorageDirectoryWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    /// Replaces whatever was being watched. `onChange` is coalesced: a rotation
    /// can fire several vnode events in a row, and one re-list is enough.
    func watch(paths: [String], onChange: @escaping @Sendable () -> Void) {
        stop()
        for path in Set(paths) {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.schedule(onChange)
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        for source in sources { source.cancel() }
        sources = []
    }

    private func schedule(_ onChange: @escaping @Sendable () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem(block: onChange)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    deinit {
        pending?.cancel()
        for source in sources { source.cancel() }
    }
}

// MARK: - Filesystem source

/// Everything `AIStorageLogsSheet` needs from disk, as four closures.
///
/// Indirection rather than calling `AIStorageModel` inline for two reasons:
/// the previews need to render every state (populated, tail-truncated, binary,
/// missing) without a real home directory behind them, and the sheet stays
/// honest about its own surface area — read operations only, no writes.
struct AIStorageLogsSource {
    var explorableTargets: @MainActor () -> [AIStorageTarget]
    var listFiles: @MainActor (String) async -> [AIStorageFileEntry]
    var open: @MainActor (AIStorageFileEntry) async -> AIStorageFileContent
    /// `(entry, endOffset, limit)` — the bounded window of older content
    /// immediately before `endOffset`.
    var loadEarlier: @MainActor (AIStorageFileEntry, Int, Int) async -> AIStorageFileContent
}

// MARK: - Model bridge
//
// Every filesystem-facing call the sheet makes goes through here, so the viewer
// stays testable against a fixture source (see `.preview()` below) and the real
// read-only wrappers live in `AIStorageModel`.
//
// `explorableTargets` filters to `exists` deliberately: the snapshot's own
// `explorableTargets` does not, because the panel wants to list a target it can
// see is absent, and the browser does not.

extension AIStorageLogsSource {
    static func live(model: AIStorageModel) -> AIStorageLogsSource {
        AIStorageLogsSource(
            explorableTargets: { model.snapshot?.explorableTargets.filter(\.exists) ?? [] },
            listFiles: { await model.listFiles(targetID: $0) },
            open: { await model.open(entry: $0) },
            loadEarlier: { await model.loadEarlier(entry: $0, before: $1, limit: $2) }
        )
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
            open: { entry in previewContent(for: entry, startOffset: previewTailStart(entry)) },
            loadEarlier: { entry, endOffset, limit in
                previewContent(for: entry, startOffset: max(0, endOffset - limit))
            }
        )
    }

    /// Where a preview file's default (tail) window begins — non-zero for the
    /// big ones, so the banner and the paging affordance are both renderable.
    private static func previewTailStart(_ entry: AIStorageFileEntry) -> Int {
        entry.sizeBytes > 262_144 ? Int(entry.sizeBytes) - 262_144 : 0
    }

    private static func previewContent(for entry: AIStorageFileEntry, startOffset: Int) -> AIStorageFileContent {
        if entry.looksBinary {
            return AIStorageFileContent(access: .ok, text: "", totalBytes: Int(entry.sizeBytes),
                                        isTruncated: false, displayPath: entry.displayPath,
                                        looksBinary: true)
        }
        if entry.name.hasSuffix(".json") {
            let json = #"{"id":"1784921389195","title":"Quantisation trade-offs","messages":[{"role":"user","content":"How much does Q4_K_M cost me on a 70B?"},{"role":"assistant","content":"Roughly 40 GB resident, versus 140 GB at fp16."}],"model":"qwen3-coder-30b"}"#
            return AIStorageFileContent(access: .ok, text: json, totalBytes: Int(entry.sizeBytes),
                                        isTruncated: false, displayPath: entry.displayPath,
                                        looksBinary: false)
        }
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
        return AIStorageFileContent(access: .ok, text: lines.joined(separator: "\n"),
                                    totalBytes: Int(entry.sizeBytes), isTruncated: startOffset > 0,
                                    displayPath: entry.displayPath, looksBinary: false,
                                    startOffset: startOffset)
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
