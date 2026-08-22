import Foundation
import Combine

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
}
