import Foundation
import Combine

/// Whether a file the "Explore logs" viewer asked to open actually came back
/// as text: `.ok` for a normal read, `.denied` when the path resolved outside
/// the allowed roots (a bug, not a user-facing path in practice), and
/// `.missingFile` when it was rotated/deleted between `listFiles` and open.
enum AIStorageFileAccess: Equatable {
    case ok
    case denied
    case missingFile
}

/// What `AIStorageModel.open(entry:)` / `loadFull(entry:)` hand back to the
/// viewer. Thin on purpose — `access` carries the outcome, `text`/`totalBytes`
/// are empty/zero for anything other than `.ok`, and `isTruncated` is always
/// `false` for `loadFull` (it reads the whole file).
struct AIStorageFileContent {
    let access: AIStorageFileAccess
    let text: String
    let totalBytes: Int
    let isTruncated: Bool
    let displayPath: String
    let looksBinary: Bool
    /// Byte offset in the file where `text` begins. `0` means the caller holds
    /// the head of the file and there is nothing older left to page in; the
    /// viewer uses it as the cursor for `loadEarlier(entry:before:limit:)`.
    var startOffset: Int = 0
}

/// Drives the Local AI Storage panel.
///
/// Deliberately *not* wired into `CollectionEngine` / `MetricsManager`: those
/// run every 2 seconds, and a scan of the oMLX KV cache takes seconds. This
/// object owns its own cadence — scan on first appear, on an explicit rescan,
/// and at most once per `minimumScanInterval` — and keeps the last result with
/// its timestamp so the panel can render "last scanned Nm ago" instead of
/// blocking or blanking.
///
/// A singleton because the panel can be hidden and re-shown (and a `@StateObject`
/// would then throw away a perfectly good scan and start another).
@MainActor
final class AIStorageModel: ObservableObject {
    static let shared = AIStorageModel()

    @Published private(set) var snapshot: AIStorageSnapshot?
    @Published private(set) var isScanning = false
    /// Set when a scan finished but produced nothing to show, so the panel can
    /// say "no local AI data" rather than presenting zeros as measured.
    @Published private(set) var lastScanFailed = false

    /// Never rescan more often than this on appear; the Rescan button bypasses it.
    private let minimumScanInterval: TimeInterval = 300

    private let collector = AIStorageCollector()
    private var scanTask: Task<Void, Never>?

    /// Set for the fixture instances the SwiftUI previews use, so a preview
    /// never walks a real 150 GB cache.
    private let isPreview: Bool

    private init() { isPreview = false }

    /// Fixture instance for `#Preview`.
    init(previewSnapshot: AIStorageSnapshot) {
        isPreview = true
        snapshot = previewSnapshot
    }

    // MARK: - Scanning

    /// Called from `.onAppear`. Cheap and idempotent: does nothing if a scan is
    /// in flight or the cached result is still fresh.
    func scanIfStale() {
        guard !isPreview, !isScanning else { return }
        if let snapshot, Date().timeIntervalSince(snapshot.scannedAt) < minimumScanInterval { return }
        rescan()
    }

    func rescan() {
        guard !isPreview else { return }
        scanTask?.cancel()
        isScanning = true
        scanTask = Task { [collector] in
            do {
                let result = try await collector.scan()
                guard !Task.isCancelled else { return }
                self.snapshot = result
                self.lastScanFailed = false
            } catch is CancellationError {
                return
            } catch {
                self.lastScanFailed = true
            }
            self.isScanning = false
        }
    }

    /// Cancels an in-flight scan (panel hidden, window closed).
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    // MARK: - Purge / search / server state

    func isOMLXRunning() async -> Bool {
        await collector.isOMLXRunning()
    }

    func stopOMLXServer() async -> Bool {
        await collector.stopOMLXServer()
    }

    func purge(targetIDs: Set<String>) async -> AIStoragePurgeResult? {
        let result = try? await collector.purge(targetIDs: targetIDs)
        rescan()
        return result
    }

    func search(_ query: String) async -> AIStorageCollector.SearchOutcome? {
        try? await collector.search(query)
    }

    // MARK: - Explore logs (read-only)

    /// Explorable targets from the last scan, present-on-disk or not — thin
    /// passthrough so the "Explore logs" entry point doesn't reach into
    /// `snapshot` directly.
    var explorableTargets: [AIStorageTarget] {
        snapshot?.explorableTargets ?? []
    }

    /// Lists the files under one explorable target. Its own fast, cancellable
    /// walk — does not touch `rescan()` or its 5-minute floor. A cancelled or
    /// failed walk comes back empty rather than throwing, since this call
    /// site has nothing meaningful to do with an error beyond "show nothing".
    func listFiles(targetID: String) async -> [AIStorageFileEntry] {
        (try? await collector.listFiles(targetID: targetID)) ?? []
    }

    /// Opens `entry` bounded to its tail (the default view).
    func open(entry: AIStorageFileEntry) async -> AIStorageFileContent {
        let result = await collector.readTail(path: entry.path)
        return AIStorageFileContent(
            access: access(for: result.status),
            text: result.text,
            totalBytes: result.totalBytes,
            isTruncated: result.truncated,
            displayPath: entry.displayPath,
            looksBinary: entry.looksBinary,
            startOffset: result.startOffset
        )
    }

    /// Pages in the bounded window of at most `limit` bytes immediately before
    /// `endOffset` — the viewer's scroll-up path, and also how *Load full file*
    /// is served (with `limit` set to everything remaining). `isTruncated` in
    /// the result means "there is still older content above this window".
    func loadEarlier(entry: AIStorageFileEntry, before endOffset: Int, limit: Int) async -> AIStorageFileContent {
        let result = await collector.readWindow(path: entry.path, endOffset: endOffset, limit: limit)
        return AIStorageFileContent(
            access: access(for: result.status),
            text: result.text,
            totalBytes: result.totalBytes,
            isTruncated: result.startOffset > 0,
            displayPath: entry.displayPath,
            looksBinary: entry.looksBinary,
            startOffset: result.startOffset
        )
    }

    /// Loads `entry` in full. Kept as a read API; the viewer itself now pages
    /// with `loadEarlier` rather than taking a whole file in one read.
    func loadFull(entry: AIStorageFileEntry) async -> AIStorageFileContent {
        let result = await collector.readFull(path: entry.path)
        return AIStorageFileContent(
            access: access(for: result.status),
            text: result.text,
            totalBytes: result.totalBytes,
            isTruncated: false,
            displayPath: entry.displayPath,
            looksBinary: entry.looksBinary
        )
    }

    private func access(for status: AIStorageCollector.ReadStatus) -> AIStorageFileAccess {
        switch status {
        case .ok: return .ok
        case .denied: return .denied
        case .missingFile: return .missingFile
        }
    }
}
