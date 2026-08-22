import XCTest
@testable import MacResourceMonitor

/// Filesystem-integration tests for the read-only Chat History APIs
/// (`listConversations` / `readTranscript` / `readChatImage`).
///
/// Every test points the collector at a fixture root via the injectable
/// `root:` initializer — never `~/.lmstudio`. That root is planted under the
/// package's own `.build` directory rather than `NSTemporaryDirectory()`:
/// `/tmp` and `/var` are BSD compatibility symlinks into `/private`, and
/// `URL.resolvingSymlinksInPath()` (used by the root guard) canonicalizes
/// through them, which makes `home.path` disagree with every resolved path.
/// See `AIStorageCollectorFileTests` for the same note.
final class AIStorageChatCollectorTests: XCTestCase {
    private var tempRoot: URL!
    private var collector: AIStorageCollector!

    private let newerDate = Date(timeIntervalSince1970: 1_784_921_389)
    private let olderDate = Date(timeIntervalSince1970: 1_776_060_921)

    override func setUp() async throws {
        try await super.setUp()
        let buildDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/AIStorageChatCollectorTests", isDirectory: true)
        tempRoot = buildDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        collector = AIStorageCollector(root: tempRoot)
        try plantTree()
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        collector = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private let pinnedConversation = """
    { "name": "Pinned chat", "pinned": true, "createdAt": 1776060921866, "tokenCount": 12,
      "systemPrompt": "", "lastUsedModel": { "identifier": "hermes-4.3-36b" },
      "messages": [ { "currentlySelected": 0, "versions": [
        { "type": "singleStep", "role": "user", "content": [ { "type": "text", "text": "pinned hello" } ] } ] } ] }
    """

    private let imageConversation = """
    { "name": "With an image", "pinned": false, "createdAt": 1784921389195, "tokenCount": 99,
      "systemPrompt": "Be brief.", "lastUsedModel": { "identifier": "qwen/qwen3.6-35b-a3b" },
      "messages": [ { "currentlySelected": 0, "versions": [
        { "type": "singleStep", "role": "user", "content": [
          { "type": "text", "text": "Describe" },
          { "type": "file", "fileIdentifier": "shot.png", "fileType": "image", "sizeBytes": 4 } ] } ] } ] }
    """

    private let previewBytes = Data("preview-bytes".utf8)
    private let fullImageBytes = Data("full-image-bytes".utf8)

    private func plantTree() throws {
        try write(imageConversation, at: ".lmstudio/conversations/1784921389195.conversation.json", mtime: newerDate)
        try write(pinnedConversation, at: ".lmstudio/conversations/1776060921866.conversation.json", mtime: olderDate)
        try write("{ \"name\": null, \"messages\": [] }", at: ".lmstudio/conversations/empty.conversation.json",
                  mtime: olderDate)
        try write("this is not json", at: ".lmstudio/conversations/broken.conversation.json", mtime: olderDate)

        try writeData(fullImageBytes, at: ".lmstudio/user-files/shot.png", mtime: newerDate)
        let sidecar = """
        { "type": "image", "sizeBytes": 4, "originalName": "screenshot.png",
          "fileIdentifier": "shot.png",
          "preview": { "data": "data:image/png;base64,\(previewBytes.base64EncodedString())" } }
        """
        try write(sidecar, at: ".lmstudio/user-files/shot.png.metadata.json", mtime: newerDate)

        // Referenced by nothing, and with no sidecar — the "full read only"
        // path.
        try writeData(fullImageBytes, at: ".lmstudio/user-files/bare.png", mtime: newerDate)
    }

    // MARK: - Listing

    func testListConversationsIsNewestFirstWithPinnedAhead() async throws {
        let listed = try await collector.listConversations()

        XCTAssertEqual(listed.count, 4)
        XCTAssertEqual(listed[0].title, "Pinned chat")
        XCTAssertTrue(listed[0].isPinned)
        XCTAssertEqual(listed[1].title, "With an image")
        // The remaining two are the untitled empty file and the unreadable one,
        // both date-titled and both still listed.
        XCTAssertTrue(listed.dropFirst(2).allSatisfy { !$0.hasExplicitTitle })
    }

    func testListedSummaryCarriesCountsAndModel() async throws {
        let listed = try await collector.listConversations()
        let withImage = try XCTUnwrap(listed.first { $0.title == "With an image" })

        XCTAssertEqual(withImage.turnCount, 1)
        XCTAssertEqual(withImage.imageCount, 1)
        XCTAssertEqual(withImage.modelName, "qwen/qwen3.6-35b-a3b")
        XCTAssertEqual(withImage.preview, "Describe Image: shot.png")
        XCTAssertTrue(withImage.displayPath.hasSuffix("1784921389195.conversation.json"))
    }

    func testUnparseableFileIsListedRatherThanDropped() async throws {
        let listed = try await collector.listConversations()
        let broken = try XCTUnwrap(listed.first { $0.fileName == "broken.conversation.json" })

        XCTAssertEqual(broken.turnCount, 0)
        XCTAssertFalse(broken.hasExplicitTitle)
        XCTAssertEqual(broken.preview, "Not readable as a conversation.")
    }

    func testMissingConversationsDirectoryListsNothing() async throws {
        let bareRoot = tempRoot.appendingPathComponent("bare", isDirectory: true)
        try FileManager.default.createDirectory(at: bareRoot, withIntermediateDirectories: true)
        let bareCollector = AIStorageCollector(root: bareRoot)

        let listed = try await bareCollector.listConversations()
        XCTAssertTrue(listed.isEmpty)
    }

    // MARK: - Reading a transcript

    func testReadTranscriptDecodesTheSelectedConversation() async throws {
        let listed = try await collector.listConversations()
        let summary = try XCTUnwrap(listed.first { $0.title == "With an image" })

        let result = await collector.readTranscript(path: summary.path,
                                                    fileName: summary.fileName,
                                                    modifiedAt: summary.modifiedAt)
        XCTAssertEqual(result.status, .ok)
        let transcript = try XCTUnwrap(result.transcript)
        XCTAssertEqual(transcript.systemPrompt, "Be brief.")
        XCTAssertEqual(transcript.imageIdentifiers, ["shot.png"])
    }

    func testReadTranscriptOfAVanishedFileIsMissingNotACrash() async {
        let path = tempRoot.appendingPathComponent(".lmstudio/conversations/gone.conversation.json").path
        let result = await collector.readTranscript(path: path,
                                                    fileName: "gone.conversation.json",
                                                    modifiedAt: newerDate)
        XCTAssertEqual(result.status, .missingFile)
        XCTAssertNil(result.transcript)
    }

    func testReadTranscriptOutsideTheAllowedRootIsDenied() async {
        let result = await collector.readTranscript(path: tempRoot.appendingPathComponent("elsewhere.json").path,
                                                    fileName: "elsewhere.json",
                                                    modifiedAt: newerDate)
        XCTAssertEqual(result.status, .denied)
        XCTAssertNil(result.transcript)
    }

    // MARK: - Images

    func testThumbnailComesFromTheSidecarPreview() async {
        let result = await collector.readChatImage(fileIdentifier: "shot.png", full: false)

        XCTAssertEqual(result.status, .ok)
        XCTAssertTrue(result.isPreview)
        XCTAssertEqual(result.data, previewBytes)
        XCTAssertEqual(result.originalName, "screenshot.png")
    }

    func testFullReadBypassesTheSidecar() async {
        let result = await collector.readChatImage(fileIdentifier: "shot.png", full: true)

        XCTAssertEqual(result.status, .ok)
        XCTAssertFalse(result.isPreview)
        XCTAssertEqual(result.data, fullImageBytes)
    }

    func testImageWithoutASidecarFallsBackToTheFile() async {
        let result = await collector.readChatImage(fileIdentifier: "bare.png", full: false)

        XCTAssertEqual(result.status, .ok)
        XCTAssertFalse(result.isPreview)
        XCTAssertEqual(result.data, fullImageBytes)
    }

    func testMissingImageIsMissingNotDenied() async {
        let result = await collector.readChatImage(fileIdentifier: "not-there.png", full: false)
        XCTAssertEqual(result.status, .missingFile)
        XCTAssertTrue(result.data.isEmpty)
    }

    func testTraversingFileIdentifierIsRefusedBeforeAnyIO() async {
        for identifier in ["../../secrets.png", "sub/dir.png", "", ".."] {
            let result = await collector.readChatImage(fileIdentifier: identifier, full: true)
            XCTAssertEqual(result.status, .denied, "expected \(identifier) to be refused")
        }
    }

    // MARK: - Read-only guarantee

    func testNothingUnderTheRootIsModified() async throws {
        let before = try snapshotTree()

        _ = try await collector.listConversations()
        let listed = try await collector.listConversations()
        for summary in listed {
            _ = await collector.readTranscript(path: summary.path,
                                               fileName: summary.fileName,
                                               modifiedAt: summary.modifiedAt)
        }
        _ = await collector.readChatImage(fileIdentifier: "shot.png", full: false)
        _ = await collector.readChatImage(fileIdentifier: "shot.png", full: true)

        XCTAssertEqual(try snapshotTree(), before)
    }

    // MARK: - Helpers

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

    private func snapshotTree() throws -> [String: Data] {
        var result: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: tempRoot, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return result }

        let prefix = tempRoot.path + "/"
        for case let item as URL in enumerator {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = item.path.hasPrefix(prefix) ? String(item.path.dropFirst(prefix.count)) : item.path
            result[relative] = (try? Data(contentsOf: item)) ?? Data()
        }
        return result
    }
}
