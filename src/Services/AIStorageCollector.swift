import Foundation

/// Scans, searches and purges what LM Studio and oMLX retain on disk from your
/// prompts.
///
/// **This collector deliberately does not run on `MetricsManager`'s 2s timer.**
/// Walking 150 GB of KV-cache shards takes seconds, not milliseconds; putting it
/// on the collection tick would make the whole app feel wedged. It is driven
/// instead by `AIStorageModel` — on panel appear, on an explicit rescan, and on
/// a 5-minute floor — and every scan runs off the main actor and is cancellable.
///
/// The oMLX cap and log-retention values come from the shared `OMLXSettings`
/// reader, the same one `OMLXCollector` polls with, so `~/.omlx/settings.json`
/// is parsed once. The API key in that file is never requested here.
actor AIStorageCollector {
    /// Scan root. Defaults to the real home directory; tests point this at a
    /// temp tree via `init(root:)` so `listFiles`/`readTail`/`readFull` can be
    /// exercised without touching `~/.lmstudio` or `~/.omlx`. The production
    /// (no-argument) path is unchanged in behavior — `home` is still
    /// `FileManager.default.homeDirectoryForCurrentUser`.
    private let home: URL
    private let settings: OMLXSettings
    private let session: URLSession

    init(settings: OMLXSettings = .shared, root: URL? = nil) {
        self.settings = settings
        self.home = root ?? FileManager.default.homeDirectoryForCurrentUser
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: - Target definitions

    /// Static description of one scan target, before it has been measured.
    private struct Spec {
        let id: String
        let provider: AIStorageProvider
        let label: String
        let relativePath: String
        let contents: String
        let note: String?
        let noteIsWarning: Bool
        let isTextSearchable: Bool
        let requiresOMLXStopped: Bool
        /// Subdirectory names measured (and purged) as their own target, so
        /// they aren't double-counted in the parent's total.
        let excludedChildren: [String]
        /// True for the three text-bearing log targets the "Explore logs"
        /// browser can open.
        let isExplorable: Bool

        init(id: String, provider: AIStorageProvider, label: String, relativePath: String,
             contents: String, note: String? = nil, noteIsWarning: Bool = false,
             isTextSearchable: Bool = true, requiresOMLXStopped: Bool = false,
             excludedChildren: [String] = [], isExplorable: Bool = false) {
            self.id = id
            self.provider = provider
            self.label = label
            self.relativePath = relativePath
            self.contents = contents
            self.note = note
            self.noteIsWarning = noteIsWarning
            self.isTextSearchable = isTextSearchable
            self.requiresOMLXStopped = requiresOMLXStopped
            self.excludedChildren = excludedChildren
            self.isExplorable = isExplorable
        }
    }

    /// Every directory we will ever look at. Nothing outside this list is
    /// scanned, searched or deleted — in particular `~/.lmstudio/models`,
    /// `~/.lmstudio/.internal/bundled-models`, `~/.omlx/bin` and
    /// `~/.omlx/settings.json` are absent by design and must stay absent.
    private static let specs: [Spec] = [
        Spec(id: "lmstudio.server-logs",
             provider: .lmStudio,
             label: "Server logs",
             relativePath: ".lmstudio/server-logs",
             contents: "Prompts and responses, verbatim. Request bodies elide the middle with “<Truncated in logs>” but the head and tail survive; responses are logged in full.",
             note: "prompts, no TTL",
             noteIsWarning: true,
             isExplorable: true),
        Spec(id: "lmstudio.conversations",
             provider: .lmStudio,
             label: "Conversations",
             relativePath: ".lmstudio/conversations",
             contents: "GUI chat history — every message you sent and received in the LM Studio app, in full text.",
             isExplorable: true),
        Spec(id: "lmstudio.user-files",
             provider: .lmStudio,
             label: "Pasted files",
             relativePath: ".lmstudio/user-files",
             contents: "Files and images pasted or dropped into the GUI, kept verbatim alongside their metadata."),
        Spec(id: "lmstudio.api-prediction-history",
             provider: .lmStudio,
             label: "API history",
             relativePath: ".lmstudio/.internal/api-prediction-history",
             contents: "History of predictions served over the local API."),
        Spec(id: "lmstudio.parsed-documents-cache",
             provider: .lmStudio,
             label: "Document cache",
             relativePath: ".lmstudio/.internal/parsed-documents-cache",
             contents: "Extracted plain text of documents you attached to a chat."),
        Spec(id: "lmstudio.cached-rag-pipeline-chunks",
             provider: .lmStudio,
             label: "RAG chunks",
             relativePath: ".lmstudio/.internal/cached-rag-pipeline-chunks",
             contents: "Chunked text of attached documents, prepared for retrieval."),
        Spec(id: "lmstudio.retrieval-sessions",
             provider: .lmStudio,
             label: "Retrieval sessions",
             relativePath: ".lmstudio/.internal/retrieval-sessions",
             contents: "Retrieval sessions built over your attached documents."),

        Spec(id: "omlx.cache",
             provider: .omlx,
             label: "Prompt KV cache",
             relativePath: ".omlx/cache",
             contents: "Key/value tensors derived from your prompts, plus GDN sidecars, boundary snapshots and response state. Binary, not plaintext — but derived from prompt content.",
             isTextSearchable: false,
             requiresOMLXStopped: true,
             excludedChildren: ["vision_features"]),
        Spec(id: "omlx.vision-features",
             provider: .omlx,
             label: "Vision features",
             relativePath: ".omlx/cache/vision_features",
             contents: "Encoded feature tensors for images you sent to a vision model.",
             isTextSearchable: false,
             requiresOMLXStopped: true),
        Spec(id: "omlx.logs",
             provider: .omlx,
             label: "Logs",
             relativePath: ".omlx/logs",
             contents: "Request metadata only — model, token counts, tok/s. No prompt text.",
             isExplorable: true),
    ]

    private func url(for spec: Spec) -> URL {
        home.appendingPathComponent(spec.relativePath)
    }

    // MARK: - Explore logs (read-only)

    /// Outcome of a root-guarded read, distinguishing "not allowed" from
    /// "vanished since it was listed" from a normal read — so
    /// `AIStorageModel`/the UI can render each state without inferring it from
    /// an empty string.
    enum ReadStatus: Equatable {
        case ok
        /// The path resolved outside `~/.lmstudio` / `~/.omlx`, or into one of
        /// the never-touch subpaths — refused before any I/O was attempted.
        case denied
        /// The path passed the root guard but nothing was there to read (the
        /// file was deleted/rotated between `listFiles` and this call).
        case missingFile
    }

    /// Lists every regular file beneath an explorable target's directory,
    /// newest first. Never mutates anything; a target that isn't
    /// `isExplorable`, or whose directory doesn't exist, comes back empty
    /// rather than throwing — this is a "show me what's there" API, not a
    /// validating one.
    ///
    /// This is intentionally its own fast, cancellable walk — it does not
    /// touch `scan()`'s 5-minute cadence or the `MetricsManager` 2s tick.
    func listFiles(targetID: String) async throws -> [AIStorageFileEntry] {
        guard let spec = Self.specs.first(where: { $0.id == targetID && $0.isExplorable }) else {
            return []
        }
        let directory = url(for: spec)
        guard directoryExists(directory) else { return [] }

        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                                       .isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [],          // hidden files count — LM Studio hides plenty
            errorHandler: { _, _ in true }
        ) else { return [] }

        let directoryPrefix = directory.path + "/"
        var entries: [AIStorageFileEntry] = []
        var checked = 0

        for case let item as URL in enumerator {
            // Cancellation checked on a stride, same rationale as `measure`:
            // the walk is ~3000 files, and `checkCancellation` per-file would
            // be needless overhead.
            checked += 1
            if checked % 256 == 0 { try Task.checkCancellation() }

            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            // Root-guard every yielded path — resolve symlinks first, exactly
            // like `isPurgeable` does for purge, then drop (never crash on)
            // anything that resolves outside the allowed roots.
            let resolvedPath = item.resolvingSymlinksInPath().standardizedFileURL.path
            guard AIStoragePathGuard.isReadable(path: resolvedPath, homePath: home.path) else { continue }

            let relativePath = item.path.hasPrefix(directoryPrefix)
                ? String(item.path.dropFirst(directoryPrefix.count))
                : item.lastPathComponent
            let modifiedAt = values.contentModificationDate ?? .distantPast
            let monthSection = spec.id == "lmstudio.server-logs"
                ? AIStorageLogLayout.monthSection(for: modifiedAt)
                : nil

            entries.append(AIStorageFileEntry(
                name: item.lastPathComponent,
                path: resolvedPath,
                displayPath: abbreviate(resolvedPath),
                relativePath: relativePath,
                sizeBytes: UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0),
                modifiedAt: modifiedAt,
                monthSection: monthSection
            ))
        }

        try Task.checkCancellation()
        return entries.sorted(by: AIStorageLogLayout.newestFirst)
    }

    /// Root-guards `path` (resolving symlinks first) and, if allowed, returns
    /// the resolved `URL`. `nil` means "denied" — callers turn that straight
    /// into `ReadStatus.denied` without touching the filesystem.
    private func resolvedIfReadable(_ path: String) -> URL? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard AIStoragePathGuard.isReadable(path: resolved.path, homePath: home.path) else { return nil }
        return resolved
    }

    /// Reads up to the last `limit` bytes of the file at `path` for the
    /// "Explore logs" viewer's default (bounded) open. Root-guards before any
    /// I/O; a denied or since-vanished file comes back as `.denied` /
    /// `.missingFile` rather than a crash or a silently-empty string.
    func readTail(path: String, limit: Int = 256 * 1024) async -> (status: ReadStatus, text: String, totalBytes: Int, truncated: Bool) {
        guard let resolved = resolvedIfReadable(path) else {
            return (.denied, "", 0, false)
        }
        guard let data = try? Data(contentsOf: resolved, options: [.mappedIfSafe]) else {
            // Vanished between `listFiles` and this call (rotated/deleted) —
            // not the same thing as "denied", and not a crash either.
            return (.missingFile, "", 0, false)
        }
        let sliced = AIStorageTailReader.sliceTail(data, limit: limit)
        return (.ok, sliced.text, sliced.totalBytes, sliced.truncated)
    }

    /// Reads the *entire* file at `path` for the viewer's explicit "load full
    /// file" action. A single unbounded read is the accepted tradeoff here:
    /// it only runs on a deliberate user action (not the default open), and
    /// in practice LM Studio's own ~10 MB rotation bounds the file size — this
    /// is not a path that scans thousands of files per tick.
    func readFull(path: String) async -> (status: ReadStatus, text: String, totalBytes: Int) {
        guard let resolved = resolvedIfReadable(path) else {
            return (.denied, "", 0)
        }
        guard let data = try? Data(contentsOf: resolved, options: [.mappedIfSafe]) else {
            return (.missingFile, "", 0)
        }
        return (.ok, String(decoding: data, as: UTF8.self), data.count)
    }

    // MARK: - Scan

    /// Measures every target. Missing directories come back `exists: false`
    /// with a zero size, so a machine with no LM Studio (or no oMLX) renders a
    /// clean panel rather than errors or fake zeros.
    ///
    /// Throws `CancellationError` if the caller's task is cancelled mid-walk.
    func scan() async throws -> AIStorageSnapshot {
        let storage = await settings.storage()
        let lmStudioTTL = readLMStudioAPIHistoryTTLDays()

        var targets: [AIStorageTarget] = []
        for spec in Self.specs {
            try Task.checkCancellation()

            let directory = url(for: spec)
            let exists = directoryExists(directory)
            let measured = exists
                ? try measure(directory, excluding: spec.excludedChildren)
                : (bytes: UInt64(0), files: 0)

            targets.append(AIStorageTarget(
                id: spec.id,
                provider: spec.provider,
                label: spec.label,
                path: directory.path,
                displayPath: "~/" + spec.relativePath,
                contents: spec.contents,
                note: note(for: spec, storage: storage, lmStudioTTL: lmStudioTTL),
                noteIsWarning: spec.noteIsWarning,
                isTextSearchable: spec.isTextSearchable,
                exists: exists,
                sizeBytes: measured.bytes,
                fileCount: measured.files,
                capBytes: spec.id == "omlx.cache" ? storage.cacheMaxSizeBytes : nil,
                requiresOMLXStopped: spec.requiresOMLXStopped,
                isExplorable: spec.isExplorable
            ))
        }

        return AIStorageSnapshot(targets: targets, scannedAt: Date())
    }

    /// Per-target annotations that depend on config read at scan time.
    private func note(for spec: Spec, storage: OMLXSettings.Storage, lmStudioTTL: Int?) -> String? {
        switch spec.id {
        case "omlx.logs":
            return storage.logRetentionDays.map { "\($0)-day retention" }
        case "omlx.cache":
            return storage.cacheMaxSizeText.map { "cap \($0)" }
        case "lmstudio.api-prediction-history":
            return lmStudioTTL.map { "\($0)-day TTL" }
        default:
            return spec.note
        }
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return found && isDirectory.boolValue
    }

    /// Sums allocated size of every regular file beneath `directory`, skipping
    /// the named immediate children (which are measured as their own targets).
    private func measure(_ directory: URL, excluding excludedChildren: [String]) throws -> (bytes: UInt64, files: Int) {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [],          // hidden files count — LM Studio hides plenty
            errorHandler: { _, _ in true }   // an unreadable subtree isn't fatal
        ) else { return (0, 0) }

        let excluded = Set(excludedChildren.map { directory.appendingPathComponent($0).path })
        var bytes: UInt64 = 0
        var files = 0
        var checked = 0

        for case let item as URL in enumerator {
            // Cancellation is checked on a stride: `checkCancellation` is cheap
            // but so is a file, and the cache has hundreds of thousands of them.
            checked += 1
            if checked % 512 == 0 { try Task.checkCancellation() }

            if excluded.contains(item.path) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            bytes += UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            files += 1
        }

        return (bytes, files)
    }

    /// `developer.apiPredictionHistoryEviction.ttlDays` out of LM Studio's own
    /// settings file. Absent app, absent key and malformed JSON all mean "no
    /// TTL to report", never an error.
    private func readLMStudioAPIHistoryTTLDays() -> Int? {
        let url = home.appendingPathComponent(".lmstudio/settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let developer = root["developer"] as? [String: Any],
              let eviction = developer["apiPredictionHistoryEviction"] as? [String: Any],
              let days = eviction["ttlDays"] as? Int else { return nil }
        return days
    }

    // MARK: - Search

    /// Result of a retained-text search. Paths and counts only, by design.
    struct SearchOutcome {
        let hits: [AIStorageSearchHit]
        let filesScanned: Int
        /// True when the file cap cut the search short, so the UI can say so
        /// rather than implying the list is complete.
        let truncated: Bool
    }

    private static let searchFileCap = 20_000

    /// Greps the text-bearing targets for `query`. Never returns the matched
    /// line or any surrounding context — the query is itself the secret, and
    /// echoing a hit just writes it to another surface.
    func search(_ query: String) async throws -> SearchOutcome {
        let needle = Array(query.utf8)
        guard !needle.isEmpty else { return SearchOutcome(hits: [], filesScanned: 0, truncated: false) }
        let lower = needle.map { asciiLower($0) }

        var hits: [AIStorageSearchHit] = []
        var scanned = 0
        var truncated = false

        for spec in Self.specs where spec.isTextSearchable {
            let directory = url(for: spec)
            guard directoryExists(directory) else { continue }

            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let item as URL in enumerator {
                try Task.checkCancellation()
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }

                if scanned >= Self.searchFileCap { truncated = true; break }
                scanned += 1

                let count = matchCount(in: item, needleLowercased: lower)
                if count > 0 {
                    hits.append(AIStorageSearchHit(
                        path: item.path,
                        displayPath: abbreviate(item.path),
                        provider: spec.provider,
                        matchCount: count
                    ))
                }
            }
            if truncated { break }
        }

        return SearchOutcome(hits: hits.sorted { $0.matchCount > $1.matchCount },
                             filesScanned: scanned,
                             truncated: truncated)
    }

    /// Case-insensitive (ASCII) occurrence count. Files are mapped rather than
    /// read so a 10 MB rotated log doesn't cost 10 MB of resident memory.
    private func matchCount(in file: URL, needleLowercased needle: [UInt8]) -> Int {
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]),
              data.count >= needle.count else { return 0 }

        return data.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            let end = raw.count - needle.count
            let first = needle[0]
            var count = 0
            var i = 0
            while i <= end {
                if asciiLower(base[i]) == first {
                    var j = 1
                    while j < needle.count, asciiLower(base[i + j]) == needle[j] { j += 1 }
                    if j == needle.count {
                        count += 1
                        i += needle.count
                        continue
                    }
                }
                i += 1
            }
            return count
        }
    }

    private func asciiLower(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? byte + 32 : byte
    }

    private func abbreviate(_ path: String) -> String {
        path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path
    }

    // MARK: - oMLX server state

    /// True when something answers on oMLX's configured loopback port. The KV
    /// cache must not be purged out from under a running server.
    func isOMLXRunning() async -> Bool {
        let endpoint = await settings.endpoint()
        var request = URLRequest(url: endpoint.base.appendingPathComponent("health"))
        request.httpMethod = "GET"
        // Any HTTP answer at all — including 503 while models preload, and 401 —
        // means the server is up and holding the cache open.
        if let (_, response) = try? await session.data(for: request),
           response is HTTPURLResponse {
            return true
        }
        return false
    }

    /// Runs `omlx stop`, then waits (up to ~10s) for the port to go quiet.
    /// Returns false if the CLI is missing, fails, or the server is still up.
    /// We never kill the process ourselves.
    func stopOMLXServer() async -> Bool {
        let candidates = ["/usr/local/bin/omlx",
                          home.appendingPathComponent(".omlx/bin/omlx").path,
                          "/opt/homebrew/bin/omlx"]
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["stop"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }

        for _ in 0..<10 {
            let running = await isOMLXRunning()
            if !running { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    // MARK: - Purge

    /// Deletes the *contents* of each named target — never the directory
    /// itself, and never anything that isn't one of `specs`. Returns what was
    /// actually freed, measured before and after.
    func purge(targetIDs: Set<String>) async throws -> AIStoragePurgeResult {
        var freed: UInt64 = 0
        var removed: [String] = []
        var failures: [String] = []

        for spec in Self.specs where targetIDs.contains(spec.id) {
            try Task.checkCancellation()

            let directory = url(for: spec)
            guard directoryExists(directory), isPurgeable(directory) else { continue }

            let before = (try? measure(directory, excluding: spec.excludedChildren))?.bytes ?? 0
            let excluded = Set(spec.excludedChildren)
            var failedHere = false

            let children = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [])) ?? []
            for child in children {
                if excluded.contains(child.lastPathComponent) { continue }
                do {
                    try FileManager.default.removeItem(at: child)
                } catch {
                    failedHere = true
                }
            }

            let after = (try? measure(directory, excluding: spec.excludedChildren))?.bytes ?? 0
            freed += before > after ? before - after : 0
            if failedHere {
                failures.append(spec.label)
            } else {
                removed.append(spec.label)
            }
        }

        return AIStoragePurgeResult(freedBytes: freed, removedTargets: removed, failures: failures)
    }

    /// Belt and braces on top of "the id came from `specs`": the resolved path
    /// must sit under `~/.lmstudio` or `~/.omlx`, must not be either of those
    /// roots, and must not be one of the never-touch paths. A symlinked target
    /// that resolves out of those roots is refused.
    private func isPurgeable(_ directory: URL) -> Bool {
        let resolved = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let lmStudioRoot = home.appendingPathComponent(".lmstudio").path
        let omlxRoot = home.appendingPathComponent(".omlx").path

        guard resolved.hasPrefix(lmStudioRoot + "/") || resolved.hasPrefix(omlxRoot + "/") else {
            return false
        }

        let denied = [
            ".lmstudio/models",
            ".lmstudio/.internal/bundled-models",
            ".omlx/bin",
            ".omlx/settings.json",
        ].map { home.appendingPathComponent($0).path }

        for path in denied where resolved == path || resolved.hasPrefix(path + "/") {
            return false
        }
        return true
    }
}

// MARK: - Pure helpers (filesystem-free, unit-testable)

/// Month-sectioning and ordering for the "Explore logs" file list. Pure and
/// locale-independent so `AIStorageLogLayoutTests` can assert on fixed dates.
enum AIStorageLogLayout {
    /// `en_US_POSIX` + a fixed UTC calendar, so the section a log lands in
    /// never shifts with the user's region or timezone settings.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    /// `YYYY-MM` for `date`, e.g. `2026-08`.
    static func monthSection(for date: Date) -> String {
        formatter.string(from: date)
    }

    /// Newest-first comparator: `modifiedAt` descending, then `name`
    /// descending as a tiebreak (matches same-second rotations by filename).
    static func newestFirst(_ a: AIStorageFileEntry, _ b: AIStorageFileEntry) -> Bool {
        if a.modifiedAt != b.modifiedAt {
            return a.modifiedAt > b.modifiedAt
        }
        return a.name > b.name
    }
}

/// The read-only analog of `AIStorageCollector.isPurgeable`: guards every path
/// the "Explore logs" browser is about to list or read. Pure — takes the
/// already-resolved path and the home directory as plain strings so it's
/// testable without touching disk.
enum AIStoragePathGuard {
    /// `path` (already symlink-resolved and standardized by the caller) must
    /// sit strictly under `homePath/.lmstudio` or `homePath/.omlx` — not equal
    /// to either root — and must not equal or be under any never-touch path.
    static func isReadable(path: String, homePath: String) -> Bool {
        let lmStudioRoot = homePath + "/.lmstudio"
        let omlxRoot = homePath + "/.omlx"

        guard path.hasPrefix(lmStudioRoot + "/") || path.hasPrefix(omlxRoot + "/") else {
            return false
        }

        let denied = [
            "/.lmstudio/models",
            "/.lmstudio/.internal/bundled-models",
            "/.omlx/bin",
            "/.omlx/settings.json",
        ].map { homePath + $0 }

        for deniedPath in denied where path == deniedPath || path.hasPrefix(deniedPath + "/") {
            return false
        }
        return true
    }
}

/// Bounded reading of a log file's tail for the "Explore logs" viewer, so a
/// 10 MB rotated log never costs 10 MB of viewer memory or a full read.
enum AIStorageTailReader {
    /// Takes the last `limit` bytes of `data`, aligns forward to the next
    /// newline so the first visible line isn't a torn fragment, and decodes
    /// the remainder as lossy UTF-8.
    static func sliceTail(_ data: Data, limit: Int) -> (text: String, totalBytes: Int, truncated: Bool) {
        guard !data.isEmpty else { return ("", 0, false) }

        let totalBytes = data.count
        guard totalBytes > limit else {
            return (String(decoding: data, as: UTF8.self), totalBytes, false)
        }

        var start = data.index(data.endIndex, offsetBy: -limit)
        // Align up to the first newline after the cut so we don't start
        // mid-line; if there is no newline in the tail (one giant line), fall
        // back to the raw cut rather than dropping the whole slice.
        if let newline = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
            start = data.index(after: newline)
        }

        let tail = data[start...]
        let text = String(decoding: tail, as: UTF8.self)
        return (text, totalBytes, totalBytes > tail.count)
    }
}
