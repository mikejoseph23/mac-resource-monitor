import XCTest
@testable import MacResourceMonitor

/// Filesystem-integration tests for the "Explore logs" read-only APIs
/// (`listFiles`/`readTail`/`readFull`) M2 added to `AIStorageCollector`.
///
/// Every test points the collector at a **temp directory** via the
/// injectable `root:` initializer — never `~/.lmstudio` or `~/.omlx`.
final class AIStorageCollectorFileTests: XCTestCase {
    private var tempRoot: URL!
    private var collector: AIStorageCollector!

    // Explicit mtimes for the standard fixture tree, set via
    // `setAttributes(_:ofItemAtPath:)` so ordering assertions are
    // deterministic rather than relying on write order.
    private let augustNewerDate = AIStorageCollectorFileTests.utcDate(2026, 8, 22, 17, 0)
    private let augustOlderDate = AIStorageCollectorFileTests.utcDate(2026, 8, 21, 3, 0)
    private let julyDate = AIStorageCollectorFileTests.utcDate(2026, 7, 31, 1, 0)
    private let conversationDate = AIStorageCollectorFileTests.utcDate(2026, 8, 20, 12, 0)
    private let omlxLogDate = AIStorageCollectorFileTests.utcDate(2026, 8, 19, 9, 0)

    private let smallLogContent = "line one\nline two\nline three\n"

    override func setUp() async throws {
        try await super.setUp()
        // Nest under the package's own `.build` directory rather than
        // `NSTemporaryDirectory()`: `/tmp` and `/var` are themselves BSD
        // compatibility symlinks to `/private/tmp` / `/private/var`, and
        // `URL.resolvingSymlinksInPath()` (used by both `listFiles`'s
        // root-guard and `readTail`/`readFull`'s `resolvedIfReadable`)
        // canonicalizes through that symlink boundary. A fake root living
        // there makes `home.path` disagree with the resolved paths the
        // collector compares it against — an artifact of the temp-dir
        // location, not a bug in the collector. `.build` sits under the repo
        // checkout, which isn't behind any such symlink.
        let buildDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/AIStorageCollectorFileTests", isDirectory: true)
        tempRoot = buildDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        collector = AIStorageCollector(root: tempRoot)
        try plantStandardTree()
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        collector = nil
        try await super.tearDown()
    }

    // MARK: - Fixture tree

    /// Plants the minimal realistic tree the milestone brief calls for:
    /// two server-log months, a conversation, an oMLX log and a stray binary
    /// file (to exercise `AIStorageFileEntry.looksBinary`).
    private func plantStandardTree() throws {
        try write(smallLogContent, at: ".lmstudio/server-logs/2026-08/2026-08-22.17.log", mtime: augustNewerDate)
        try write("older august line\n", at: ".lmstudio/server-logs/2026-08/2026-08-21.03.log", mtime: augustOlderDate)
        try write("july line\n", at: ".lmstudio/server-logs/2026-07/2026-07-31.1.log", mtime: julyDate)
        try write("{\"messages\":[]}\n", at: ".lmstudio/conversations/1784921389195.conversation.json",
                  mtime: conversationDate)
        try write("stray binary blob", at: ".lmstudio/conversations/weights.bin", mtime: conversationDate)
        try write("request served\n", at: ".omlx/logs/server.log", mtime: omlxLogDate)
    }

    /// Writes `content` at `relativePath` under `tempRoot`, creating
    /// intermediate directories, and stamps the modification date.
    @discardableResult
    private func write(_ content: String, at relativePath: String, mtime: Date) throws -> URL {
        try writeData(Data(content.utf8), at: relativePath, mtime: mtime)
    }

    @discardableResult
    private func writeData(_ data: Data, at relativePath: String, mtime: Date) throws -> URL {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    private static func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return calendar.date(from: components)!
    }

    /// Recursively snapshots every regular file under `tempRoot` (relative
    /// path -> content, plus symlink targets by their destination string) so
    /// tests can assert the planted tree is byte-identical after a read-only
    /// pass.
    private func snapshotTree() throws -> [String: Data] {
        var result: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: tempRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []
        ) else { return result }

        let prefix = tempRoot.path + "/"
        for case let item as URL in enumerator {
            let relative = item.path.hasPrefix(prefix) ? String(item.path.dropFirst(prefix.count)) : item.path
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: item.path)) ?? ""
                result["symlink:\(relative)"] = Data(target.utf8)
            } else if values?.isRegularFile == true {
                result["file:\(relative)"] = (try? Data(contentsOf: item)) ?? Data()
            }
        }
        return result
    }

    // MARK: - listFiles: presence

    func testListFilesReturnsEntriesForPresentTarget() async throws {
        let entries = try await collector.listFiles(targetID: "lmstudio.server-logs")
        XCTAssertEqual(entries.count, 3)
    }

    func testListFilesReturnsEmptyForMissingTarget() async throws {
        // "lmstudio.user-files" is a real target ID but wasn't planted.
        let entries = try await collector.listFiles(targetID: "lmstudio.user-files")
        XCTAssertEqual(entries, [])
    }

    func testListFilesReturnsEmptyForUnknownTargetID() async throws {
        let entries = try await collector.listFiles(targetID: "not-a-real-target")
        XCTAssertEqual(entries, [])
    }

    // MARK: - listFiles: ordering

    func testListFilesOrdersNewestFirst() async throws {
        let entries = try await collector.listFiles(targetID: "lmstudio.server-logs")
        XCTAssertEqual(entries.map(\.name), [
            "2026-08-22.17.log",
            "2026-08-21.03.log",
            "2026-07-31.1.log",
        ])
        // Cross-check directly against the mtimes we planted.
        XCTAssertEqual(entries.map(\.modifiedAt), [augustNewerDate, augustOlderDate, julyDate])
    }

    // MARK: - listFiles: monthSection

    func testMonthSectionPopulatedForServerLogs() async throws {
        let entries = try await collector.listFiles(targetID: "lmstudio.server-logs")
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        XCTAssertEqual(byName["2026-08-22.17.log"]?.monthSection, "2026-08")
        XCTAssertEqual(byName["2026-08-21.03.log"]?.monthSection, "2026-08")
        XCTAssertEqual(byName["2026-07-31.1.log"]?.monthSection, "2026-07")
    }

    func testMonthSectionNilForConversationsAndOMLXLogs() async throws {
        let conversations = try await collector.listFiles(targetID: "lmstudio.conversations")
        for entry in conversations {
            XCTAssertNil(entry.monthSection, "\(entry.name) should not carry a month section")
        }

        let omlxLogs = try await collector.listFiles(targetID: "omlx.logs")
        for entry in omlxLogs {
            XCTAssertNil(entry.monthSection, "\(entry.name) should not carry a month section")
        }
    }

    // MARK: - listFiles: field correctness

    func testEntryFieldsArePopulatedCorrectly() async throws {
        let entries = try await collector.listFiles(targetID: "lmstudio.server-logs")
        guard let entry = entries.first(where: { $0.name == "2026-08-22.17.log" }) else {
            return XCTFail("expected the August 22 log entry")
        }

        XCTAssertEqual(entry.relativePath, "2026-08/2026-08-22.17.log")
        XCTAssertEqual(entry.displayPath, "~/.lmstudio/server-logs/2026-08/2026-08-22.17.log")
        XCTAssertEqual(entry.modifiedAt, augustNewerDate)
        // Allocated size can round up to the filesystem's block size but
        // never rounds down below the actual content length.
        XCTAssertGreaterThanOrEqual(entry.sizeBytes, UInt64(smallLogContent.utf8.count))
        XCTAssertGreaterThan(entry.sizeBytes, 0)
    }

    func testStrayBinaryFileIsFlaggedLooksBinary() async throws {
        let entries = try await collector.listFiles(targetID: "lmstudio.conversations")
        guard let binary = entries.first(where: { $0.name == "weights.bin" }) else {
            return XCTFail("expected the planted weights.bin entry")
        }
        XCTAssertTrue(binary.looksBinary)

        guard let json = entries.first(where: { $0.name.hasSuffix(".conversation.json") }) else {
            return XCTFail("expected the planted conversation.json entry")
        }
        XCTAssertFalse(json.looksBinary)
    }

    // MARK: - listFiles: symlink escaping the root is dropped

    func testFileResolvingOutsideAllowedRootsIsDropped() async throws {
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIStorageCollectorFileTests-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }

        let outsideFile = outsideDir.appendingPathComponent("secret.log")
        try Data("outside content".utf8).write(to: outsideFile)

        let escapingLink = tempRoot.appendingPathComponent(".lmstudio/conversations/escape.json")
        try FileManager.default.createSymbolicLink(at: escapingLink, withDestinationURL: outsideFile)

        // Must not crash, and must not surface the escaping entry.
        let entries = try await collector.listFiles(targetID: "lmstudio.conversations")
        XCTAssertFalse(entries.contains { $0.name == "escape.json" })
        // The legitimate sibling entries are unaffected.
        XCTAssertTrue(entries.contains { $0.name == "1784921389195.conversation.json" })
    }

    // MARK: - listFiles: cancellation

    func testCancellationDuringWalkThrowsCancellationError() async throws {
        // Plant enough files that the per-256-item cancellation check inside
        // the walk is guaranteed to fire (rather than depending on timing).
        for i in 0..<300 {
            try write("filler\n", at: ".lmstudio/conversations/filler-\(i).json", mtime: conversationDate)
        }

        let task = Task {
            try await collector.listFiles(targetID: "lmstudio.conversations")
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    // MARK: - readTail

    func testReadTailSmallFileReturnsExactContent() async throws {
        let path = tempRoot.appendingPathComponent(".lmstudio/server-logs/2026-08/2026-08-22.17.log").path
        let result = await collector.readTail(path: path)
        XCTAssertEqual(result.status, .ok)
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.text, smallLogContent)
        XCTAssertEqual(result.totalBytes, smallLogContent.utf8.count)
    }

    func testReadTailLargeFileIsTruncated() async throws {
        let limit = 256 * 1024
        let lines = (0..<30_000).map { String(format: "line-%06d\n", $0) }
        let content = lines.joined()
        XCTAssertGreaterThan(content.utf8.count, limit, "fixture must exceed the tail limit")

        let url = try write(content, at: ".omlx/logs/big.log", mtime: omlxLogDate)
        let result = await collector.readTail(path: url.path, limit: limit)

        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.totalBytes, content.utf8.count)
        XCTAssertTrue(content.hasSuffix(result.text))
        XCTAssertFalse(result.text.isEmpty)
    }

    func testReadTailOutsideRootsIsDenied() async throws {
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIStorageCollectorFileTests-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        let outsideFile = outsideDir.appendingPathComponent("secret.log")
        try Data("do not read me".utf8).write(to: outsideFile)

        let result = await collector.readTail(path: outsideFile.path)
        XCTAssertEqual(result.status, .denied)
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.totalBytes, 0)
        XCTAssertFalse(result.truncated)

        // No read performed: the source file is untouched.
        let stillThere = try Data(contentsOf: outsideFile)
        XCTAssertEqual(stillThere, Data("do not read me".utf8))
    }

    func testReadTailMissingFileUnderValidRoot() async throws {
        let url = try write("temporary\n", at: ".omlx/logs/rotated.log", mtime: omlxLogDate)
        try FileManager.default.removeItem(at: url)

        let result = await collector.readTail(path: url.path)
        XCTAssertEqual(result.status, .missingFile)
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.totalBytes, 0)
        XCTAssertFalse(result.truncated)
    }

    // MARK: - readFull

    func testReadFullReturnsCompleteContent() async throws {
        let lines = (0..<5_000).map { String(format: "entry-%05d\n", $0) }
        let content = lines.joined()
        let url = try write(content, at: ".lmstudio/server-logs/2026-08/full.log", mtime: augustNewerDate)

        let result = await collector.readFull(path: url.path)
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.text, content)
        XCTAssertEqual(result.totalBytes, content.utf8.count)
    }

    // MARK: - No mutation

    func testReadOnlyAPIsDoNotMutatePlantedTree() async throws {
        let before = try snapshotTree()

        _ = try await collector.listFiles(targetID: "lmstudio.server-logs")
        _ = try await collector.listFiles(targetID: "lmstudio.conversations")
        _ = try await collector.listFiles(targetID: "omlx.logs")
        _ = await collector.readTail(
            path: tempRoot.appendingPathComponent(".lmstudio/server-logs/2026-08/2026-08-22.17.log").path)
        _ = await collector.readFull(
            path: tempRoot.appendingPathComponent(".omlx/logs/server.log").path)

        let after = try snapshotTree()
        XCTAssertEqual(before, after, "read-only APIs must never mutate the scanned tree")
    }
}
