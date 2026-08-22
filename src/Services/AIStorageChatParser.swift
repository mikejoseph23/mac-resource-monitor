import Foundation

/// Decoding of LM Studio's saved GUI conversations into something renderable as
/// a transcript.
///
/// **Pure and filesystem-free by construction** — every entry point takes
/// `Data` (or already-extracted values) and returns value types, so
/// `AIStorageChatParserTests` can exercise the whole layer from a JSON literal,
/// the same way `AIStorageLogLayout` / `AIStorageTailReader` are tested.
///
/// Defensive on purpose. These files are written by another app that is free to
/// change its schema between releases: an unknown `type`, a missing key, an
/// out-of-range `currentlySelected` or a message with no versions at all must
/// degrade to "render what we understood" rather than throwing the whole
/// conversation away. Nothing in here throws.

// MARK: - Value types

enum AIStorageChatRole: String, Hashable {
    case user
    case assistant
    case system
    case unknown

    init(raw: String?) {
        self = AIStorageChatRole(rawValue: raw ?? "") ?? .unknown
    }

    var label: String {
        switch self {
        case .user:      return "You"
        case .assistant: return "Assistant"
        case .system:    return "System"
        case .unknown:   return "Message"
        }
    }
}

/// One renderable piece of a turn. `reasoning` is split out from `text` because
/// the viewer treats it completely differently (collapsed, visually recessed),
/// and `debug` because it isn't conversation at all.
enum AIStorageChatPart: Identifiable, Hashable {
    case text(id: String, text: String)
    /// A `contentBlock` whose `style.type == "thinking"`. `title` is LM Studio's
    /// own "Thought for 19.35 seconds" label when it wrote one.
    case reasoning(id: String, title: String?, text: String)
    case image(id: String, fileIdentifier: String, sizeBytes: UInt64)
    /// A non-image `file` content part — rendered as a chip, never read.
    case attachment(id: String, fileIdentifier: String, kind: String, sizeBytes: UInt64)
    case debug(id: String, text: String)
    /// A `type` this parser doesn't know. Kept rather than dropped, so a schema
    /// change shows up as one honest line instead of a silently missing turn.
    case unknown(id: String, label: String)

    var id: String {
        switch self {
        case .text(let id, _),
             .reasoning(let id, _, _),
             .image(let id, _, _),
             .attachment(let id, _, _, _),
             .debug(let id, _),
             .unknown(let id, _):
            return id
        }
    }

    var isReasoning: Bool {
        if case .reasoning = self { return true }
        return false
    }

    var isDebug: Bool {
        if case .debug = self { return true }
        return false
    }

    /// Everything that belongs in the turn's main body — i.e. not reasoning and
    /// not debug metadata.
    var isBody: Bool { !isReasoning && !isDebug }
}

/// One message, already resolved to the version the user last had selected.
struct AIStorageChatTurn: Identifiable, Hashable {
    let id: String
    let index: Int
    let role: AIStorageChatRole
    /// `senderInfo.senderName` — the model id that produced an assistant turn.
    let senderName: String?
    /// Zero-based index of the rendered version, and how many regenerations
    /// exist. `versionCount > 1` drives the subtle "2 of 3" affordance.
    let versionIndex: Int
    let versionCount: Int
    let parts: [AIStorageChatPart]

    var bodyParts: [AIStorageChatPart] { parts.filter(\.isBody) }
    var reasoningParts: [AIStorageChatPart] { parts.filter(\.isReasoning) }
    var debugParts: [AIStorageChatPart] { parts.filter(\.isDebug) }

    /// True for a message whose selected version carried nothing renderable —
    /// an interrupted generation, or a schema we didn't understand at all.
    var isEmpty: Bool { parts.isEmpty }

    /// Plain-text summary of the body, for the list preview and VoiceOver.
    var plainText: String {
        bodyParts.compactMap { part in
            switch part {
            case .text(_, let text):                        return text
            case .image(_, let identifier, _):              return "Image: \(identifier)"
            case .attachment(_, let identifier, _, _):      return "File: \(identifier)"
            case .unknown(_, let label):                    return label
            default:                                        return nil
            }
        }
        .joined(separator: "\n")
    }
}

/// One decoded conversation file, ready to render.
struct AIStorageChatTranscript {
    let title: String
    /// False when `title` was synthesized from the file's date because the
    /// conversation had no `name` — the list italicizes those.
    let hasExplicitTitle: Bool
    /// `lastUsedModel.identifier`, when present.
    let modelName: String?
    let createdAt: Date?
    let tokenCount: Int?
    let isPinned: Bool
    /// `nil` (never an empty string) when the conversation has no system prompt.
    let systemPrompt: String?
    let turns: [AIStorageChatTurn]

    /// Every image the transcript references, de-duplicated in first-seen order
    /// — the sheet's thumbnail loader walks this rather than the turns.
    var imageIdentifiers: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for turn in turns {
            for part in turn.parts {
                if case .image(_, let identifier, _) = part, seen.insert(identifier).inserted {
                    result.append(identifier)
                }
            }
        }
        return result
    }
}

/// One row in the conversation list. Built from the same parse as the
/// transcript, so the list and the viewer can never disagree about a title.
struct AIStorageChatSummary: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let displayPath: String
    let fileName: String
    let title: String
    let hasExplicitTitle: Bool
    let modelName: String?
    let turnCount: Int
    let imageCount: Int
    let isPinned: Bool
    /// When the conversation was started — the epoch-millis filename stem when
    /// it parses, otherwise `createdAt`, otherwise the file's mtime.
    let createdAt: Date
    let modifiedAt: Date
    let sizeBytes: UInt64
    /// First user line, for the second row of the list cell. Empty when the
    /// conversation has no messages.
    let preview: String
}

/// A conversation image, resolved either to its cheap sidecar preview or to the
/// real file on disk.
struct AIStorageChatImage {
    let access: AIStorageFileAccess
    let data: Data
    let originalName: String?
    let sizeBytes: Int
    /// True when `data` came from the sidecar's base64 preview rather than the
    /// full PNG — the enlarge action asks for the full one.
    let isPreview: Bool

    static func failed(_ access: AIStorageFileAccess) -> AIStorageChatImage {
        AIStorageChatImage(access: access, data: Data(), originalName: nil, sizeBytes: 0, isPreview: false)
    }
}

// MARK: - Parser

enum AIStorageChatParser {

    /// Decodes one `<epochMillis>.conversation.json`. Returns `nil` only when
    /// the bytes aren't a JSON object at all; anything else — unknown types,
    /// missing keys, zero messages — comes back as a transcript that renders.
    static func transcript(fromJSON data: Data, fileName: String, modifiedAt: Date) -> AIStorageChatTranscript? {
        guard let root = jsonObject(data) else { return nil }

        let name = (root["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let created = createdDate(fileName: fileName, root: root, modifiedAt: modifiedAt)
        let rawMessages = root["messages"] as? [Any] ?? []

        var turns: [AIStorageChatTurn] = []
        turns.reserveCapacity(rawMessages.count)
        for (index, raw) in rawMessages.enumerated() {
            if let turn = turn(from: raw, index: index) {
                turns.append(turn)
            }
        }

        let systemPrompt = (root["systemPrompt"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }

        return AIStorageChatTranscript(
            title: name ?? fallbackTitle(for: created),
            hasExplicitTitle: name != nil,
            modelName: modelName(root["lastUsedModel"]),
            createdAt: created,
            tokenCount: (root["tokenCount"] as? NSNumber)?.intValue,
            isPinned: root["pinned"] as? Bool ?? false,
            systemPrompt: systemPrompt,
            turns: turns
        )
    }

    /// The list row for an already-decoded transcript.
    static func summary(for transcript: AIStorageChatTranscript,
                        path: String,
                        displayPath: String,
                        fileName: String,
                        sizeBytes: UInt64,
                        modifiedAt: Date) -> AIStorageChatSummary {
        let firstUserLine = transcript.turns
            .first { $0.role == .user }
            .map(\.plainText) ?? ""

        return AIStorageChatSummary(
            path: path,
            displayPath: displayPath,
            fileName: fileName,
            title: transcript.title,
            hasExplicitTitle: transcript.hasExplicitTitle,
            modelName: transcript.modelName,
            turnCount: transcript.turns.count,
            imageCount: transcript.imageIdentifiers.count,
            isPinned: transcript.isPinned,
            createdAt: transcript.createdAt ?? modifiedAt,
            modifiedAt: modifiedAt,
            sizeBytes: sizeBytes,
            preview: condense(firstUserLine)
        )
    }

    /// The row for a file we couldn't decode — listed, honestly labelled, and
    /// still openable (the viewer then shows its own unreadable state) rather
    /// than vanishing from the list.
    static func unreadableSummary(path: String,
                                  displayPath: String,
                                  fileName: String,
                                  sizeBytes: UInt64,
                                  modifiedAt: Date) -> AIStorageChatSummary {
        let created = stemDate(fileName: fileName) ?? modifiedAt
        return AIStorageChatSummary(
            path: path,
            displayPath: displayPath,
            fileName: fileName,
            title: fallbackTitle(for: created),
            hasExplicitTitle: false,
            modelName: nil,
            turnCount: 0,
            imageCount: 0,
            isPinned: false,
            createdAt: created,
            modifiedAt: modifiedAt,
            sizeBytes: sizeBytes,
            preview: "Not readable as a conversation."
        )
    }

    /// Newest-first, pinned conversations ahead of the rest — the ordering LM
    /// Studio's own sidebar uses, and the one the list renders in.
    static func newestFirst(_ a: AIStorageChatSummary, _ b: AIStorageChatSummary) -> Bool {
        if a.isPinned != b.isPinned { return a.isPinned }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.fileName > b.fileName
    }

    // MARK: - Messages

    /// One `{ versions: [...], currentlySelected: Int }` entry. `nil` only when
    /// the entry isn't an object; a message whose selected version is missing
    /// or unparseable still yields an (empty) turn, so the transcript keeps its
    /// shape and the viewer can say so.
    static func turn(from raw: Any, index: Int) -> AIStorageChatTurn? {
        guard let message = raw as? [String: Any] else { return nil }

        let versions = message["versions"] as? [Any] ?? []
        let requested = (message["currentlySelected"] as? NSNumber)?.intValue ?? 0
        // Out-of-range selections clamp rather than crash — LM Studio has been
        // seen to write an index for a version it then dropped.
        let selected = versions.isEmpty ? 0 : min(max(requested, 0), versions.count - 1)
        let version = versions.indices.contains(selected) ? versions[selected] as? [String: Any] : nil

        let role = AIStorageChatRole(raw: version?["role"] as? String)
        let sender = (version?["senderInfo"] as? [String: Any])?["senderName"] as? String

        return AIStorageChatTurn(
            id: "turn-\(index)",
            index: index,
            role: role,
            senderName: sender.flatMap { $0.isEmpty ? nil : $0 },
            versionIndex: selected,
            versionCount: versions.count,
            parts: parts(ofVersion: version, turnIndex: index)
        )
    }

    private static func parts(ofVersion version: [String: Any]?, turnIndex: Int) -> [AIStorageChatPart] {
        guard let version else { return [] }

        switch version["type"] as? String {
        case "multiStep":
            let steps = version["steps"] as? [Any] ?? []
            return steps.enumerated().flatMap { stepIndex, step in
                parts(ofStep: step, turnIndex: turnIndex, stepIndex: stepIndex)
            }
        case "singleStep", .none:
            return contentParts(version["content"], turnIndex: turnIndex, stepIndex: 0, isThinking: false)
        case .some(let other):
            // An unrecognized version type still often carries `content` or
            // `steps`; try both before admitting we don't know what it is.
            let fromContent = contentParts(version["content"], turnIndex: turnIndex, stepIndex: 0, isThinking: false)
            if !fromContent.isEmpty { return fromContent }
            let steps = version["steps"] as? [Any] ?? []
            let fromSteps = steps.enumerated().flatMap { stepIndex, step in
                parts(ofStep: step, turnIndex: turnIndex, stepIndex: stepIndex)
            }
            if !fromSteps.isEmpty { return fromSteps }
            return [.unknown(id: "\(turnIndex).0.unknown", label: "Unsupported message type “\(other)”")]
        }
    }

    private static func parts(ofStep raw: Any, turnIndex: Int, stepIndex: Int) -> [AIStorageChatPart] {
        guard let step = raw as? [String: Any] else { return [] }

        switch step["type"] as? String {
        case "contentBlock":
            let style = step["style"] as? [String: Any]
            let isThinking = (style?["type"] as? String) == "thinking"
            let title = style?["title"] as? String
            let parts = contentParts(step["content"], turnIndex: turnIndex, stepIndex: stepIndex,
                                     isThinking: isThinking, reasoningTitle: title)
            return parts

        case "debugInfoBlock":
            let text = debugText(step["debugInfo"])
            guard !text.isEmpty else { return [] }
            return [.debug(id: "\(turnIndex).\(stepIndex).debug", text: text)]

        case .some(let other):
            // Tool calls and whatever LM Studio adds next land here. Surface
            // the step rather than dropping it, but keep it out of the body's
            // way by labelling it plainly.
            return [.unknown(id: "\(turnIndex).\(stepIndex).unknown", label: "Unsupported step “\(other)”")]

        case .none:
            return []
        }
    }

    private static func contentParts(_ raw: Any?,
                                     turnIndex: Int,
                                     stepIndex: Int,
                                     isThinking: Bool,
                                     reasoningTitle: String? = nil) -> [AIStorageChatPart] {
        guard let items = raw as? [Any] else { return [] }

        var result: [AIStorageChatPart] = []
        for (partIndex, item) in items.enumerated() {
            guard let part = item as? [String: Any] else { continue }
            let id = "\(turnIndex).\(stepIndex).\(partIndex)"

            switch part["type"] as? String {
            case "text":
                guard let text = part["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append(isThinking
                    ? .reasoning(id: id, title: reasoningTitle, text: text)
                    : .text(id: id, text: text))

            case "file":
                guard let identifier = part["fileIdentifier"] as? String, !identifier.isEmpty else { continue }
                let bytes = (part["sizeBytes"] as? NSNumber)?.uint64Value ?? 0
                let kind = part["fileType"] as? String ?? "file"
                result.append(kind == "image"
                    ? .image(id: id, fileIdentifier: identifier, sizeBytes: bytes)
                    : .attachment(id: id, fileIdentifier: identifier, kind: kind, sizeBytes: bytes))

            case .some(let other):
                result.append(.unknown(id: id, label: "Unsupported content “\(other)”"))

            case .none:
                continue
            }
        }
        return result
    }

    /// `debugInfo` is a string today; a future object/array is rendered as
    /// compact JSON rather than "(unknown)".
    private static func debugText(_ raw: Any?) -> String {
        switch raw {
        case let text as String:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .none:
            return ""
        case .some(let other):
            guard JSONSerialization.isValidJSONObject(other),
                  let data = try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys]) else {
                return String(describing: other)
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// LM Studio writes both `identifier` (the short, human one) and
    /// `indexedModelIdentifier` (the full repo path); the short one is what its
    /// own UI shows.
    private static func modelName(_ raw: Any?) -> String? {
        guard let model = raw as? [String: Any] else { return nil }
        let candidates = [model["identifier"] as? String, model["indexedModelIdentifier"] as? String]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    // MARK: - Images

    /// Pulls the ready-to-render thumbnail out of a `<file>.metadata.json`
    /// sidecar. `preview.data` is a `data:` URI, so this is the whole reason
    /// the viewer never has to read a 2 MB PNG to show a 200 pt thumbnail.
    static func previewImageData(fromMetadataJSON data: Data) -> (data: Data, originalName: String?, sizeBytes: Int)? {
        guard let root = jsonObject(data) else { return nil }
        let originalName = (root["originalName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let sizeBytes = (root["sizeBytes"] as? NSNumber)?.intValue ?? 0
        guard let preview = root["preview"] as? [String: Any],
              let uri = preview["data"] as? String,
              let decoded = decodeDataURI(uri) else { return nil }
        return (decoded, originalName, sizeBytes)
    }

    /// Decodes the base64 payload of a `data:` URI. Returns `nil` for anything
    /// that isn't one (including the `;charset=`/percent-encoded forms, which
    /// LM Studio never writes and this viewer has no reason to render).
    static func decodeDataURI(_ uri: String) -> Data? {
        guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.startIndex..<comma]
        guard header.hasSuffix(";base64") else { return nil }
        let payload = String(uri[uri.index(after: comma)...])
        return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
    }

    /// A `fileIdentifier` is a bare filename by construction. Anything with a
    /// path separator in it is refused here, *before* the root guard gets a
    /// chance to — defense in depth against a crafted conversation file.
    static func isSafeFileIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.count < 512 else { return false }
        guard !identifier.contains("/"), !identifier.contains("\\"), !identifier.contains("\0") else { return false }
        return identifier != "." && identifier != ".."
    }

    // MARK: - Dates and titles

    /// When the conversation was started. The filename stem is the most
    /// reliable of the three sources (LM Studio names the file after the
    /// creation instant), so it wins; `createdAt` is the fallback, and the
    /// file's mtime the last resort — `empty.conversation.json` has neither a
    /// numeric stem nor a non-zero `createdAt`.
    static func createdDate(fileName: String, root: [String: Any], modifiedAt: Date) -> Date {
        if let fromStem = stemDate(fileName: fileName) { return fromStem }
        if let millis = (root["createdAt"] as? NSNumber)?.doubleValue, millis > 0 {
            return Date(timeIntervalSince1970: millis / 1000)
        }
        return modifiedAt
    }

    /// `1784921389195.conversation.json` → that instant. `nil` for a stem that
    /// isn't epoch milliseconds, or one so far out of range it can only be
    /// garbage.
    static func stemDate(fileName: String) -> Date? {
        let stem = fileName.split(separator: ".").first.map(String.init) ?? fileName
        guard !stem.isEmpty, stem.allSatisfy(\.isNumber), let millis = Double(stem) else { return nil }
        let seconds = millis / 1000
        // ~1990 to ~2100: anything outside that is a filename that merely
        // happens to be numeric.
        guard seconds > 631_152_000, seconds < 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The title a conversation with no `name` gets: its date, written the way
    /// a person would say it.
    static func fallbackTitle(for date: Date) -> String {
        titleFormatter.string(from: date)
    }

    /// Section header for the list: "August 2026". Fixed `en_US_POSIX` so the
    /// grouping is stable and testable, matching `AIStorageLogLayout`'s rationale.
    static func monthTitle(for date: Date) -> String {
        monthFormatter.string(from: date)
    }

    /// One line, whitespace collapsed, clipped — a list cell never renders a
    /// 4000-character paste.
    static func condense(_ text: String, limit: Int = 140) -> String {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Private

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = parsed as? [String: Any] else { return nil }
        return object
    }

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy 'at' HH:mm"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()
}
