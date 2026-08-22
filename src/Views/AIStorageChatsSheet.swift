import SwiftUI
import AppKit

/// "Let me actually read this chat."
///
/// The transcript-rendering sibling of `AIStorageLogsSheet`. That sheet answers
/// "what did the server just log?" with Console.app's dense monospaced tail;
/// this one answers "what did I actually say to that model?", and a JSON dump
/// is the wrong shape for the question — so the conversation is rendered as a
/// conversation: turns by role, reasoning folded away, images inline.
///
/// Strictly read-only by construction: no delete, rename, move or write
/// affordance exists anywhere in this view, and the only things it asks the
/// model for are a listing, one decoded transcript, and image bytes.
///
/// Deliberately *not* a mode of the logs sheet: that view's byte-window paging
/// machinery has nothing to do with a 100 KB JSON document read whole, and
/// bolting a second personality onto a 1300-line view would have made both
/// worse.
struct AIStorageChatsSheet: View {
    @ObservedObject var model: AIStorageModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// Prose scales with the user's text-size setting; the few monospaced bits
    /// (paths, debug metadata) scale within bounds — see `monoFont`.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    /// Everything this sheet needs from the filesystem, behind three closures.
    /// Same rationale as `AIStorageLogsSource`: the previews render every state
    /// without a home directory, and the surface area stays visibly read-only.
    private let source: AIStorageChatsSource

    init(model: AIStorageModel, source: AIStorageChatsSource? = nil) {
        self.model = model
        self.source = source ?? .live(model: model)
    }

    // MARK: - State

    @State private var summaries: [AIStorageChatSummary] = []
    @State private var listPhase: ListPhase = .idle
    @State private var listTask: Task<Void, Never>?

    @State private var selection: AIStorageChatSummary?
    /// Keyboard cursor, separate from `selection` exactly as in the logs sheet:
    /// arrows move the highlight without decoding a file, Return opens it.
    @State private var cursor: AIStorageChatSummary?
    @State private var transcript: AIStorageChatTranscript?
    @State private var transcriptAccess: AIStorageFileAccess = .ok
    @State private var isOpening = false
    /// Bumped per open; a result carrying a stale generation is dropped, so a
    /// slow decode can't land on top of a conversation opened after it.
    @State private var openGeneration = 0
    @State private var openTask: Task<Void, Never>?

    @State private var query = ""
    @State private var showsDebugInfo = false
    @State private var systemPromptExpanded = false
    /// Reasoning blocks are collapsed by default; this holds the ones the user
    /// has opened, keyed by part id, and is cleared on every new transcript.
    @State private var expandedReasoning: Set<String> = []

    @State private var images: [String: ImageState] = [:]
    @State private var enlarged: EnlargedImage?

    @FocusState private var listFocused: Bool

    private enum ListPhase: Equatable {
        case idle, listing, listed
    }

    /// One image's lifecycle. `.ready` holds the decoded thumbnail only — the
    /// full-size file is never loaded until the user enlarges it.
    private enum ImageState {
        case loading
        case ready(NSImage, isPreview: Bool, sizeBytes: Int, originalName: String?)
        case missing
        case denied
    }

    /// The full-size image being shown over the sheet.
    private struct EnlargedImage: Identifiable {
        let id: String
        let image: NSImage
        let originalName: String?
        let sizeBytes: Int
        /// True when the enlarge fell back to the thumbnail because the real
        /// file is gone — the overlay says so rather than pretending.
        let isPreview: Bool
    }

    // MARK: - Derived

    private var visibleSummaries: [AIStorageChatSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return summaries }
        return summaries.filter { summary in
            summary.title.lowercased().contains(trimmed)
                || summary.preview.lowercased().contains(trimmed)
                || (summary.modelName?.lowercased().contains(trimmed) ?? false)
        }
    }

    /// Pinned conversations get their own leading section; everything else is
    /// grouped by the month it was started, newest month first. `summaries` is
    /// already in that order, so this only has to walk it once.
    private var sections: [(title: String, summaries: [AIStorageChatSummary])] {
        var result: [(String, [AIStorageChatSummary])] = []
        for summary in visibleSummaries {
            let title = summary.isPinned ? "Pinned" : AIStorageChatParser.monthTitle(for: summary.createdAt)
            if var last = result.last, last.0 == title {
                last.1.append(summary)
                result[result.count - 1] = last
            } else {
                result.append((title, [summary]))
            }
        }
        return result.map { (title: $0.0, summaries: $0.1) }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()

            HStack(spacing: 0) {
                conversationList
                    .frame(width: 300)
                Divider()
                transcriptPane
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 520)

            Divider()
            footer
        }
        .frame(width: 820)
        .task {
            guard listPhase == .idle else { return }
            startList()
        }
        .onDisappear {
            // Nothing survives the sheet: no orphaned listing, no orphaned
            // decode, no retained image bytes.
            listTask?.cancel()
            listTask = nil
            openTask?.cancel()
            openTask = nil
            images = [:]
        }
        .sheet(item: $enlarged) { item in
            enlargedImageView(item)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(.secondary)
            Text("Chat History")
                .font(uiFont(13, weight: .semibold))
            Text("LM Studio")
                .font(uiFont(11))
                .foregroundStyle(.tertiary)

            Spacer()

            if listPhase == .listed, !summaries.isEmpty {
                Text("\(summaries.count) conversation\(summaries.count == 1 ? "" : "s")")
                    .font(uiFont(11))
                    .foregroundStyle(.secondary)
            }

            Text("read-only")
                .font(uiFont(10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07))
                )
                .accessibilityLabel("This browser is read-only")

            Button {
                startList(preservingSelection: true)
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
            .disabled(listPhase == .listing)
            .help("Re-read the conversations folder")
            .accessibilityLabel("Reload conversations")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Conversation list

    private var conversationList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("Filter by title or model", text: $query)
                    .textFieldStyle(.plain)
                    .font(uiFont(11))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            Group {
                switch listPhase {
                case .idle, .listing:
                    if summaries.isEmpty {
                        listPlaceholder(icon: "clock",
                                        title: "Reading conversations…",
                                        detail: nil,
                                        showsSpinner: true)
                    } else {
                        rows
                    }
                case .listed:
                    if summaries.isEmpty {
                        listPlaceholder(icon: "bubble.left.and.bubble.right",
                                        title: "No saved chats",
                                        detail: "LM Studio hasn't stored any GUI conversations on this Mac.",
                                        showsSpinner: false)
                    } else if visibleSummaries.isEmpty {
                        listPlaceholder(icon: "line.3.horizontal.decrease.circle",
                                        title: "Nothing matches “\(query)”",
                                        detail: "\(summaries.count) conversation\(summaries.count == 1 ? "" : "s") hidden by the filter.",
                                        showsSpinner: false,
                                        action: ("Clear filter", { query = "" }))
                    } else {
                        rows
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(sidebarBackground)
    }

    /// `LazyVStack` with pinned headers, matching the logs sheet. The folder is
    /// small today, but it grows one file per chat and never rotates.
    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        Section {
                            ForEach(section.summaries) { summary in
                                conversationRow(summary)
                                    .id(summary.id)
                            }
                        } header: {
                            sectionHeader(section.title, count: section.summaries.count)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .animation(.easeInOut(duration: 0.16), value: query)
            .focusable()
            .focused($listFocused)
            .onMoveCommand { direction in moveCursor(direction, proxy: proxy) }
            .onKeyPress(.return) {
                guard let cursor else { return .ignored }
                select(cursor)
                return .handled
            }
            .accessibilityLabel("Conversations")
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            if title == "Pinned" {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(uiFont(10, weight: .semibold))
            Spacer(minLength: 4)
            Text("\(count)")
                .font(monoFont(10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) conversation\(count == 1 ? "" : "s")")
        .accessibilityAddTraits(.isHeader)
    }

    private func conversationRow(_ summary: AIStorageChatSummary) -> some View {
        let isSelected = selection?.id == summary.id
        let isCursor = cursor?.id == summary.id

        return Button {
            cursor = summary
            listFocused = true
            select(summary)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if summary.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.orange)
                    }
                    // A conversation LM Studio never named shows its date
                    // instead, italicized so the list doesn't read as if the
                    // user titled it that.
                    Text(summary.title)
                        .font(uiFont(12, weight: isSelected ? .semibold : .regular))
                        .italic(!summary.hasExplicitTitle)
                        .foregroundStyle(summary.hasExplicitTitle ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(relativeDay(summary.createdAt))
                        .font(uiFont(10))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }

                if !summary.preview.isEmpty {
                    Text(summary.preview)
                        .font(uiFont(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                HStack(spacing: 6) {
                    Label("\(summary.turnCount)", systemImage: "text.bubble")
                        .labelStyle(.titleAndIcon)
                    if summary.imageCount > 0 {
                        Label("\(summary.imageCount)", systemImage: "photo")
                            .labelStyle(.titleAndIcon)
                    }
                    if let model = summary.modelName {
                        Text(model)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(uiFont(10))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(selectionWashOpacity) : Color.clear)
            }
            .overlay {
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
        .help(summary.displayPath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel(summary))
        .accessibilityHint("Opens this conversation as a transcript")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func rowAccessibilityLabel(_ summary: AIStorageChatSummary) -> String {
        var parts = [summary.hasExplicitTitle ? summary.title : "Untitled chat from \(summary.title)"]
        parts.append("\(summary.turnCount) message\(summary.turnCount == 1 ? "" : "s")")
        if summary.imageCount > 0 {
            parts.append("\(summary.imageCount) image\(summary.imageCount == 1 ? "" : "s")")
        }
        if let model = summary.modelName { parts.append("model \(model)") }
        if summary.isPinned { parts.append("pinned") }
        parts.append(accessibleTimestamp(summary.createdAt))
        return parts.joined(separator: ", ")
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
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(uiFont(10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
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

    // MARK: - Transcript pane

    @ViewBuilder
    private var transcriptPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selection {
                transcriptToolbar(selection)
                Divider()
            }

            Group {
                if selection == nil {
                    panePlaceholder(icon: "bubble.left.and.text.bubble.right",
                                    title: "Select a conversation to read it",
                                    detail: "Chats render as transcripts — reasoning folded away, images inline.")
                } else if isOpening {
                    panePlaceholder(icon: "clock", title: "Opening…", detail: nil, showsSpinner: true)
                } else if transcriptAccess == .denied {
                    panePlaceholder(icon: "lock",
                                    title: "macOS wouldn't allow reading this file",
                                    detail: selection?.displayPath)
                } else if let transcript {
                    if transcript.turns.isEmpty {
                        panePlaceholder(icon: "bubble.left",
                                        title: "This chat has no messages",
                                        detail: "LM Studio saved the conversation before anything was said in it.")
                    } else {
                        transcriptBody(transcript)
                    }
                } else {
                    panePlaceholder(icon: "questionmark.folder",
                                    title: "Couldn't read that conversation",
                                    detail: "It was deleted since the list was built, or it isn't a conversation file any more.",
                                    action: ("Reload conversations", { startList() }))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func transcriptToolbar(_ summary: AIStorageChatSummary) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(transcript?.title ?? summary.title)
                    .font(uiFont(12, weight: .semibold))
                    .italic(!(transcript?.hasExplicitTitle ?? summary.hasExplicitTitle))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                HStack(spacing: 5) {
                    Text(accessibleTimestamp(summary.createdAt))
                    if let model = transcript?.modelName ?? summary.modelName {
                        Text("·").foregroundStyle(.tertiary)
                        Text(model).lineLimit(1).truncationMode(.middle)
                    }
                    if let tokens = transcript?.tokenCount, tokens > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(tokens) tokens")
                    }
                }
                .font(uiFont(10))
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(toolbarAccessibilityLabel(summary))

            Spacer(minLength: 8)

            if transcript?.turns.contains(where: { !$0.debugParts.isEmpty }) == true {
                Toggle(isOn: $showsDebugInfo) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show LM Studio's per-message debug metadata")
                .accessibilityLabel("Show debug metadata")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: summary.path)])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func toolbarAccessibilityLabel(_ summary: AIStorageChatSummary) -> String {
        var parts = ["Viewing \(transcript?.title ?? summary.title)"]
        if let model = transcript?.modelName ?? summary.modelName { parts.append("model \(model)") }
        parts.append("\(transcript?.turns.count ?? summary.turnCount) messages")
        parts.append(accessibleTimestamp(summary.createdAt))
        return parts.joined(separator: ", ")
    }

    private func transcriptBody(_ transcript: AIStorageChatTranscript) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let prompt = transcript.systemPrompt {
                    systemPromptBlock(prompt)
                }
                // Position in the array, not `turn.index`: a message this
                // parser skipped entirely leaves a gap in the indices, and the
                // separator must still not trail the last turn.
                ForEach(Array(transcript.turns.enumerated()), id: \.element.id) { position, turn in
                    turnView(turn)
                    if position != transcript.turns.count - 1 {
                        Divider()
                            .padding(.leading, 44)
                            .padding(.vertical, 2)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityLabel("Transcript of \(transcript.title)")
    }

    /// Present, readable, and quiet — the system prompt is context for the
    /// conversation, not part of it, so it sits above the first turn folded up.
    private func systemPromptBlock(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.14)) { systemPromptExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(systemPromptExpanded ? 90 : 0))
                    Image(systemName: "gearshape")
                        .font(.system(size: 9))
                    Text("System prompt")
                        .font(uiFont(10, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("System prompt")
            .accessibilityValue(systemPromptExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isButton)

            if systemPromptExpanded {
                Text(prompt)
                    .font(uiFont(11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.04))
        }
        .padding(.bottom, 12)
    }

    // MARK: - One turn

    /// A gutter glyph plus content, rather than alternating left/right bubbles:
    /// this is a reading view inside a system utility, and Mail's threaded
    /// idiom sits better next to the logs sheet than a messaging app's does.
    /// The user's own words still get a filled surface so the eye can find them
    /// while scrolling.
    private func turnView(_ turn: AIStorageChatTurn) -> some View {
        HStack(alignment: .top, spacing: 10) {
            roleGlyph(turn)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 6) {
                turnHeader(turn)

                ForEach(turn.reasoningParts) { part in
                    reasoningBlock(part)
                }

                if turn.bodyParts.isEmpty, turn.reasoningParts.isEmpty {
                    Text(turn.isEmpty ? "This message has no saved content." : "Nothing to show for this message.")
                        .font(uiFont(11))
                        .italic()
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(turn.bodyParts) { part in
                        bodyPart(part, role: turn.role)
                    }
                }

                if showsDebugInfo {
                    ForEach(turn.debugParts) { part in
                        debugBlock(part)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(turnAccessibilityLabel(turn))
    }

    private func roleGlyph(_ turn: AIStorageChatTurn) -> some View {
        ZStack {
            Circle()
                .fill(turn.role == .user
                      ? Color.accentColor.opacity(colorScheme == .dark ? 0.30 : 0.18)
                      : Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.07))
            Image(systemName: turn.role == .user ? "person.fill" : "cube")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(turn.role == .user ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    private func turnHeader(_ turn: AIStorageChatTurn) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(turn.role == .assistant ? (turn.senderName ?? "Assistant") : turn.role.label)
                .font(uiFont(11, weight: .semibold))
                .foregroundStyle(turn.role == .user ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)

            // Regenerations: LM Studio keeps every version, and quietly saying
            // which one is on screen is more honest than rendering it as if it
            // were the only answer.
            if turn.versionCount > 1 {
                Text("version \(turn.versionIndex + 1) of \(turn.versionCount)")
                    .font(uiFont(9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06)))
                    .help("This message was regenerated; LM Studio had this version selected.")
            }

            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func bodyPart(_ part: AIStorageChatPart, role: AIStorageChatRole) -> some View {
        switch part {
        case .text(_, let text):
            Text(text)
                .font(uiFont(12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(role == .user ? 9 : 0)
                .background {
                    if role == .user {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.09))
                    }
                }

        case .image(_, let identifier, let sizeBytes):
            imageView(identifier: identifier, declaredBytes: sizeBytes)

        case .attachment(_, let identifier, let kind, let sizeBytes):
            attachmentChip(identifier: identifier, kind: kind, sizeBytes: sizeBytes)

        case .unknown(_, let label):
            HStack(spacing: 5) {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: 10))
                Text(label)
                    .font(uiFont(11))
            }
            .foregroundStyle(.tertiary)

        case .reasoning, .debug:
            // Routed elsewhere in `turnView`; never reached.
            EmptyView()
        }
    }

    /// Reasoning is the model talking to itself. It is genuinely interesting
    /// and almost never what you opened the chat to read — so it is folded,
    /// labelled with LM Studio's own "Thought for 19.35 seconds", and recessed
    /// behind a rule when open.
    private func reasoningBlock(_ part: AIStorageChatPart) -> some View {
        guard case .reasoning(let id, let title, let text) = part else {
            return AnyView(EmptyView())
        }
        let isExpanded = expandedReasoning.contains(id)
        let label = title ?? "Reasoning"

        return AnyView(
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        if isExpanded { expandedReasoning.remove(id) } else { expandedReasoning.insert(id) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Image(systemName: "brain")
                            .font(.system(size: 9))
                        Text(label)
                            .font(uiFont(10, weight: .medium))
                        if !isExpanded {
                            Text("· \(approximateWordCount(text)) words")
                                .font(uiFont(10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reasoning, \(label)")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Shows the model's internal reasoning for this answer")

                if isExpanded {
                    Text(text)
                        .font(uiFont(11))
                        .italic()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.14))
                                .frame(width: 2)
                        }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.035))
            }
        )
    }

    private func debugBlock(_ part: AIStorageChatPart) -> some View {
        guard case .debug(_, let text) = part else { return AnyView(EmptyView()) }
        return AnyView(
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 9))
                Text(text)
                    .font(monoFont(10))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 1)
            }
            .accessibilityLabel("Debug metadata: \(text)")
        )
    }

    // MARK: - Images

    @ViewBuilder
    private func imageView(identifier: String, declaredBytes: UInt64) -> some View {
        switch images[identifier] {
        case .ready(let image, let isPreview, let sizeBytes, let originalName):
            Button {
                enlarge(identifier: identifier, fallback: image, isPreview: isPreview,
                        sizeBytes: sizeBytes, originalName: originalName)
            } label: {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 260, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.10), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help("\(originalName ?? identifier) — click to enlarge")
            .accessibilityLabel("Image \(originalName ?? identifier), \(aiStorageFormatBytes(UInt64(max(sizeBytes, Int(declaredBytes)))))")
            .accessibilityHint("Opens the full-size image")
            .accessibilityAddTraits(.isButton)

        case .missing:
            imagePlaceholder(icon: "photo.badge.exclamationmark",
                             title: "Image not on disk",
                             detail: identifier)

        case .denied:
            imagePlaceholder(icon: "lock",
                             title: "Image refused",
                             detail: identifier)

        case .loading, .none:
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
                .frame(width: 180, height: 120)
                .overlay { ProgressView().controlSize(.small).scaleEffect(0.7) }
                .accessibilityLabel("Loading image")
                .task { await loadThumbnail(identifier) }
        }
    }

    private func imagePlaceholder(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(placeholderGlyph)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(uiFont(11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(monoFont(10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: 300, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.20 : 0.12))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(detail)")
    }

    private func attachmentChip(identifier: String, kind: String, sizeBytes: UInt64) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
                .font(.system(size: 10))
            Text(identifier)
                .font(uiFont(11))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(sizeBytes > 0 ? aiStorageFormatBytes(sizeBytes) : kind)
                .font(monoFont(10))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Attached \(kind) \(identifier)")
    }

    private func enlargedImageView(_ item: EnlargedImage) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
                Text(item.originalName ?? item.id)
                    .font(uiFont(12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.sizeBytes > 0 {
                    Text(aiStorageFormatBytes(UInt64(item.sizeBytes)))
                        .font(monoFont(10))
                        .foregroundStyle(.secondary)
                }
                if item.isPreview {
                    Text("preview only")
                        .font(uiFont(10, weight: .medium))
                        .foregroundStyle(.orange)
                        .help("The original file is no longer on disk; this is LM Studio's saved thumbnail.")
                }
                Spacer(minLength: 8)
                Button("Close") { enlarged = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Image(nsImage: item.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
                .background(Color(nsColor: .textBackgroundColor))
                .accessibilityLabel("Full-size image \(item.originalName ?? item.id)")
        }
        .frame(width: 720, height: 560)
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

    // MARK: - Actions

    private func startList(preservingSelection: Bool = false) {
        listTask?.cancel()
        listTask = Task { await list(preservingSelection: preservingSelection) }
    }

    private func list(preservingSelection: Bool) async {
        let keepID = preservingSelection ? selection?.id : nil

        if !preservingSelection {
            withAnimation(.easeInOut(duration: 0.16)) {
                listPhase = .listing
                summaries = []
                selection = nil
                cursor = nil
                transcript = nil
            }
            images = [:]
        } else {
            listPhase = .listing
        }

        let listed = await source.listConversations()
        guard !Task.isCancelled else { return }

        withAnimation(.easeInOut(duration: 0.16)) {
            summaries = listed
            listPhase = .listed
        }

        if let keepID, let stillThere = listed.first(where: { $0.id == keepID }) {
            // The conversation being read survived the reload: leave it, and
            // its scroll position, exactly where it was.
            selection = stillThere
            cursor = stillThere
            return
        }

        // Nothing opens by itself: unlike a log, where "what did it just say?"
        // has one obvious answer, picking a chat for the user would be a guess.
        cursor = visibleSummaries.first ?? listed.first
    }

    private func select(_ summary: AIStorageChatSummary) {
        guard selection?.id != summary.id || transcript == nil else { return }
        selection = summary
        transcript = nil
        transcriptAccess = .ok
        expandedReasoning = []
        systemPromptExpanded = false
        showsDebugInfo = false
        images = [:]
        isOpening = true
        openGeneration += 1
        let generation = openGeneration

        openTask?.cancel()
        openTask = Task {
            let result = await source.loadTranscript(summary)
            guard generation == openGeneration, !Task.isCancelled else { return }
            isOpening = false
            transcriptAccess = result.access
            withAnimation(.easeInOut(duration: 0.14)) {
                transcript = result.transcript
            }
        }
    }

    /// Thumbnails are pulled one at a time, on the image's own `.task`, so a
    /// transcript with ten images costs ten small sidecar reads *as they scroll
    /// into view* rather than a burst on open. Nothing full-size is ever loaded
    /// here.
    private func loadThumbnail(_ identifier: String) async {
        guard images[identifier] == nil else { return }
        images[identifier] = .loading
        let generation = openGeneration

        let result = await source.loadImage(identifier, false)
        guard generation == openGeneration, !Task.isCancelled else { return }

        switch result.access {
        case .ok:
            if let image = NSImage(data: result.data) {
                images[identifier] = .ready(image, isPreview: result.isPreview,
                                            sizeBytes: result.sizeBytes,
                                            originalName: result.originalName)
            } else {
                images[identifier] = .missing
            }
        case .missingFile:
            images[identifier] = .missing
        case .denied:
            images[identifier] = .denied
        }
    }

    /// Enlarging is the only time the full file is read. If it has since been
    /// deleted, the sidecar thumbnail already in hand is shown instead, labelled
    /// as a preview rather than passed off as the original.
    private func enlarge(identifier: String,
                         fallback: NSImage,
                         isPreview: Bool,
                         sizeBytes: Int,
                         originalName: String?) {
        enlarged = EnlargedImage(id: identifier, image: fallback, originalName: originalName,
                                 sizeBytes: sizeBytes, isPreview: isPreview)
        guard isPreview else { return }

        Task {
            let full = await source.loadImage(identifier, true)
            guard full.access == .ok, let image = NSImage(data: full.data) else { return }
            guard enlarged?.id == identifier else { return }
            enlarged = EnlargedImage(id: identifier, image: image,
                                     originalName: originalName ?? full.originalName,
                                     sizeBytes: full.sizeBytes > 0 ? full.sizeBytes : sizeBytes,
                                     isPreview: false)
        }
    }

    private func moveCursor(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        let list = visibleSummaries
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

    // MARK: - Appearance

    private var sidebarBackground: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.03)
    }

    private var selectionWashOpacity: Double {
        colorScheme == .dark ? 0.28 : 0.16
    }

    private var placeholderGlyph: HierarchicalShapeStyle {
        colorScheme == .dark ? .tertiary : .quaternary
    }

    private func panePlaceholder(icon: String,
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
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(uiFont(11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
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

    private func uiFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * typeScale, weight: weight)
    }

    /// Same clamp as the logs sheet: monospaced text tracks the text-size
    /// setting but never shrinks below its design size and never runs away.
    private func monoFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: min(max(size * typeScale, size), size + 6), weight: weight, design: .monospaced)
    }

    // MARK: - Formatting

    private func turnAccessibilityLabel(_ turn: AIStorageChatTurn) -> String {
        let who = turn.role == .assistant ? (turn.senderName ?? "Assistant") : turn.role.label
        var parts = ["\(who) said"]
        if !turn.reasoningParts.isEmpty { parts.append("with reasoning, collapsed") }
        if turn.versionCount > 1 { parts.append("version \(turn.versionIndex + 1) of \(turn.versionCount)") }
        let body = AIStorageChatParser.condense(turn.plainText, limit: 400)
        parts.append(body.isEmpty ? "no saved content" : body)
        return parts.joined(separator: ", ")
    }

    /// "3h ago" for today, "Jul 24" for this year, "Jul 24, 2025" before that —
    /// the same shape Mail's message list uses.
    private func relativeDay(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 3_600 { return "\(max(1, Int(seconds / 60)))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        let calendar = Calendar.current
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return Self.dayFormatter.string(from: date)
        }
        return Self.dayYearFormatter.string(from: date)
    }

    private func accessibleTimestamp(_ date: Date) -> String {
        Self.accessibleFormatter.string(from: date)
    }

    private func approximateWordCount(_ text: String) -> Int {
        max(1, text.split(whereSeparator: \.isWhitespace).count)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let dayYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    private static let accessibleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Filesystem source

/// Everything `AIStorageChatsSheet` needs from disk, as three closures — read
/// operations only. Same indirection as `AIStorageLogsSource`, for the same two
/// reasons: renderable previews without a home directory, and a view whose
/// entire filesystem surface is visible in one struct.
struct AIStorageChatsSource {
    var listConversations: @MainActor () async -> [AIStorageChatSummary]
    var loadTranscript: @MainActor (AIStorageChatSummary) async -> (access: AIStorageFileAccess, transcript: AIStorageChatTranscript?)
    /// `(fileIdentifier, full)` — `full == false` is the cheap sidecar preview.
    var loadImage: @MainActor (String, Bool) async -> AIStorageChatImage
}

extension AIStorageChatsSource {
    static func live(model: AIStorageModel) -> AIStorageChatsSource {
        AIStorageChatsSource(
            listConversations: { await model.listConversations() },
            loadTranscript: { await model.loadTranscript($0) },
            loadImage: { await model.loadChatImage(fileIdentifier: $0, full: $1) }
        )
    }
}

// MARK: - Previews

#if DEBUG
extension AIStorageChatsSource {
    /// Fixture source built by running the *real* parser over a conversation
    /// literal — so a preview that renders proves the decoding path as well as
    /// the layout.
    static func preview(conversations: [(name: String, json: String)] = AIStorageChatFixtures.conversations)
        -> AIStorageChatsSource {
        let decoded: [(summary: AIStorageChatSummary, transcript: AIStorageChatTranscript)] =
            conversations.enumerated().compactMap { index, item in
                let modified = Date().addingTimeInterval(-Double(index) * 86_400)
                guard let transcript = AIStorageChatParser.transcript(
                    fromJSON: Data(item.json.utf8), fileName: item.name, modifiedAt: modified
                ) else { return nil }
                let summary = AIStorageChatParser.summary(
                    for: transcript,
                    path: "/x/.lmstudio/conversations/\(item.name)",
                    displayPath: "~/.lmstudio/conversations/\(item.name)",
                    fileName: item.name,
                    sizeBytes: UInt64(item.json.utf8.count),
                    modifiedAt: modified
                )
                return (summary, transcript)
            }

        return AIStorageChatsSource(
            listConversations: { decoded.map(\.summary).sorted(by: AIStorageChatParser.newestFirst) },
            loadTranscript: { summary in
                guard let match = decoded.first(where: { $0.summary.id == summary.id }) else {
                    return (.missingFile, nil)
                }
                return (.ok, match.transcript)
            },
            loadImage: { identifier, _ in
                guard identifier.hasPrefix("fixture"),
                      let data = AIStorageChatFixtures.swatchPNG() else {
                    return .failed(.missingFile)
                }
                return AIStorageChatImage(access: .ok, data: data, originalName: "screenshot.png",
                                          sizeBytes: data.count, isPreview: true)
            }
        )
    }
}

/// Conversation literals shaped exactly like LM Studio's own files, so the
/// previews cover: a titled chat with an image and a thinking step, an untitled
/// one (date-titled fallback), a regenerated message, and a zero-message file.
enum AIStorageChatFixtures {
    static let conversations: [(name: String, json: String)] = [
        (name: "1784921389195.conversation.json", json: rich),
        (name: "1784679064871.conversation.json", json: untitledWithVersions),
        (name: "empty.conversation.json", json: empty),
    ]

    static let rich = """
    {
      "name": "Spreadsheet Data Description",
      "pinned": true,
      "createdAt": 1784921389195,
      "tokenCount": 2146,
      "systemPrompt": "You are a careful analyst. Prefer plain language over jargon.",
      "lastUsedModel": { "identifier": "qwen/qwen3.6-35b-a3b" },
      "messages": [
        { "currentlySelected": 0, "versions": [ {
            "type": "singleStep", "role": "user",
            "content": [
              { "type": "text", "text": "Describe what this spreadsheet is showing, and flag anything that looks wrong." },
              { "type": "file", "fileIdentifier": "fixture-screenshot.png", "fileType": "image", "sizeBytes": 100050 }
            ] } ] },
        { "currentlySelected": 0, "versions": [ {
            "type": "multiStep", "role": "assistant",
            "senderInfo": { "senderName": "qwen/qwen3.6-35b-a3b" },
            "steps": [
              { "type": "contentBlock",
                "style": { "type": "thinking", "ended": true, "title": "Thought for 19.35 seconds" },
                "content": [ { "type": "text", "text": "The user wants a description of the provided image. It is a screenshot of a spreadsheet. I should identify the columns, summarise the data, then look for inconsistencies in the totals column before answering." } ] },
              { "type": "contentBlock",
                "content": [ { "type": "text", "text": "This is a quarterly revenue sheet with one row per region and a computed total column.\\n\\nTwo things look off:\\n\\n1. The Q3 total for EMEA is 4,120 but its parts sum to 4,102 — a transposition.\\n2. Row 14 is formatted as text, so it is excluded from the column sum entirely." } ] },
              { "type": "debugInfoBlock", "debugInfo": "Conversation naming technique: 'prompt'" }
            ] } ] }
      ]
    }
    """

    static let untitledWithVersions = """
    {
      "pinned": false,
      "createdAt": 1784679064871,
      "tokenCount": 777,
      "systemPrompt": "",
      "lastUsedModel": { "identifier": "deepseek-v4-flash" },
      "messages": [
        { "currentlySelected": 0, "versions": [ {
            "type": "singleStep", "role": "user",
            "content": [ { "type": "text", "text": "Hey — are you there?" } ] } ] },
        { "currentlySelected": 1, "versions": [
            { "type": "multiStep", "role": "assistant", "senderInfo": { "senderName": "deepseek-v4-flash" },
              "steps": [ { "type": "contentBlock", "content": [ { "type": "text", "text": "Yes." } ] } ] },
            { "type": "multiStep", "role": "assistant", "senderInfo": { "senderName": "deepseek-v4-flash" },
              "steps": [ { "type": "contentBlock", "content": [ { "type": "text", "text": "I'm here. What would you like to work on?" } ] } ] },
            { "type": "multiStep", "role": "assistant", "senderInfo": { "senderName": "deepseek-v4-flash" },
              "steps": [ { "type": "contentBlock", "content": [ { "type": "text", "text": "Here and listening." } ] } ] }
          ] },
        { "currentlySelected": 0, "versions": [ {
            "type": "singleStep", "role": "user",
            "content": [
              { "type": "text", "text": "Take a look at this one too." },
              { "type": "file", "fileIdentifier": "1776319533209 - 120.png", "fileType": "image", "sizeBytes": 88120 },
              { "type": "file", "fileIdentifier": "notes.pdf", "fileType": "document", "sizeBytes": 41230 }
            ] } ] }
      ]
    }
    """

    static let empty = """
    { "name": null, "pinned": false, "createdAt": 0, "tokenCount": 0,
      "systemPrompt": "", "lastUsedModel": { "identifier": "qwen/qwen3.6-35b-a3b" }, "messages": [] }
    """

    /// A small generated PNG, so the image path renders in a preview without
    /// shipping an asset.
    static func swatchPNG() -> Data? {
        let size = NSSize(width: 320, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.withAlphaComponent(0.35).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.systemIndigo.setFill()
        NSRect(x: 24, y: 24, width: 120, height: 80).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

#Preview("Populated") {
    AIStorageChatsSheet(model: AIStorageModel(previewSnapshot: .preview),
                        source: .preview())
}

#Preview("No conversations") {
    AIStorageChatsSheet(model: AIStorageModel(previewSnapshot: .preview),
                        source: .preview(conversations: []))
}
#endif
