import XCTest
@testable import MacResourceMonitor

/// Unit tests for the pure conversation-decoding layer behind the Chat History
/// viewer. Everything here runs from a JSON literal — no filesystem, no home
/// directory — mirroring `AIStorageTailReaderTests`.
final class AIStorageChatParserTests: XCTestCase {

    private let modified = Date(timeIntervalSince1970: 1_760_000_000)

    private func parse(_ json: String,
                       fileName: String = "1784921389195.conversation.json") -> AIStorageChatTranscript? {
        AIStorageChatParser.transcript(fromJSON: Data(json.utf8), fileName: fileName, modifiedAt: modified)
    }

    // MARK: - A realistic conversation

    /// The shape actually on disk: user text + an image part, an assistant with
    /// a thinking step, a normal answer step and a `debugInfoBlock`.
    private let realistic = """
    {
      "name": "Spreadsheet Data Description",
      "pinned": true,
      "createdAt": 1784921389195,
      "tokenCount": 2146,
      "systemPrompt": "You are a careful analyst.",
      "lastUsedModel": { "identifier": "qwen/qwen3.6-35b-a3b",
                         "indexedModelIdentifier": "qwen/qwen3.6-35b-a3b-GGUF/q8.gguf" },
      "messages": [
        { "currentlySelected": 0, "versions": [ {
            "type": "singleStep", "role": "user",
            "content": [
              { "type": "text", "text": "Describe" },
              { "type": "file", "fileIdentifier": "1784921393420 - 431.png",
                "fileType": "image", "sizeBytes": 100050 }
            ] } ] },
        { "currentlySelected": 0, "versions": [ {
            "type": "multiStep", "role": "assistant",
            "senderInfo": { "senderName": "qwen/qwen3.6-35b-a3b" },
            "steps": [
              { "type": "contentBlock",
                "style": { "type": "thinking", "ended": true, "title": "Thought for 19.35 seconds" },
                "content": [ { "type": "text", "text": "The user wants a description." } ] },
              { "type": "contentBlock",
                "content": [ { "type": "text", "text": "It is a quarterly revenue sheet." } ] },
              { "type": "debugInfoBlock", "debugInfo": "Conversation naming technique: 'prompt'" }
            ] } ] }
      ]
    }
    """

    func testRealisticConversationHeader() throws {
        let transcript = try XCTUnwrap(parse(realistic))

        XCTAssertEqual(transcript.title, "Spreadsheet Data Description")
        XCTAssertTrue(transcript.hasExplicitTitle)
        XCTAssertTrue(transcript.isPinned)
        XCTAssertEqual(transcript.tokenCount, 2146)
        XCTAssertEqual(transcript.systemPrompt, "You are a careful analyst.")
        // The short `identifier` wins over `indexedModelIdentifier`, matching
        // what LM Studio's own UI shows.
        XCTAssertEqual(transcript.modelName, "qwen/qwen3.6-35b-a3b")
        XCTAssertEqual(transcript.turns.count, 2)
    }

    func testUserTurnCarriesTextAndImage() throws {
        let transcript = try XCTUnwrap(parse(realistic))
        let user = transcript.turns[0]

        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(user.versionCount, 1)
        XCTAssertEqual(user.bodyParts.count, 2)

        guard case .text(_, let text) = user.bodyParts[0] else { return XCTFail("expected text part") }
        XCTAssertEqual(text, "Describe")

        guard case .image(_, let identifier, let bytes) = user.bodyParts[1] else {
            return XCTFail("expected image part")
        }
        XCTAssertEqual(identifier, "1784921393420 - 431.png")
        XCTAssertEqual(bytes, 100_050)
        XCTAssertEqual(transcript.imageIdentifiers, ["1784921393420 - 431.png"])
    }

    func testAssistantThinkingStepBecomesReasoningAndDebugIsSeparate() throws {
        let transcript = try XCTUnwrap(parse(realistic))
        let assistant = transcript.turns[1]

        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.senderName, "qwen/qwen3.6-35b-a3b")

        XCTAssertEqual(assistant.reasoningParts.count, 1)
        guard case .reasoning(_, let title, let reasoning) = assistant.reasoningParts[0] else {
            return XCTFail("expected reasoning part")
        }
        XCTAssertEqual(title, "Thought for 19.35 seconds")
        XCTAssertEqual(reasoning, "The user wants a description.")

        // The answer is the only body part — reasoning and debug are routed out.
        XCTAssertEqual(assistant.bodyParts.count, 1)
        guard case .text(_, let answer) = assistant.bodyParts[0] else { return XCTFail("expected answer") }
        XCTAssertEqual(answer, "It is a quarterly revenue sheet.")

        XCTAssertEqual(assistant.debugParts.count, 1)
        guard case .debug(_, let debug) = assistant.debugParts[0] else { return XCTFail("expected debug") }
        XCTAssertEqual(debug, "Conversation naming technique: 'prompt'")
    }

    func testPartIdentifiersAreUnique() throws {
        let transcript = try XCTUnwrap(parse(realistic))
        let ids = transcript.turns.flatMap { $0.parts.map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: - Versions

    func testSelectedVersionIsRendered() throws {
        let json = """
        { "name": "Regens", "messages": [
          { "currentlySelected": 1, "versions": [
            { "type": "multiStep", "role": "assistant",
              "steps": [ { "type": "contentBlock", "content": [ { "type": "text", "text": "first" } ] } ] },
            { "type": "multiStep", "role": "assistant",
              "steps": [ { "type": "contentBlock", "content": [ { "type": "text", "text": "second" } ] } ] },
            { "type": "multiStep", "role": "assistant",
              "steps": [ { "type": "contentBlock", "content": [ { "type": "text", "text": "third" } ] } ] }
          ] } ] }
        """
        let turn = try XCTUnwrap(parse(json)?.turns.first)

        XCTAssertEqual(turn.versionIndex, 1)
        XCTAssertEqual(turn.versionCount, 3)
        XCTAssertEqual(turn.plainText, "second")
    }

    func testOutOfRangeSelectionClampsRatherThanLosingTheMessage() throws {
        let json = """
        { "messages": [
          { "currentlySelected": 7, "versions": [
            { "type": "singleStep", "role": "user", "content": [ { "type": "text", "text": "only one" } ] } ] } ] }
        """
        let turn = try XCTUnwrap(parse(json)?.turns.first)

        XCTAssertEqual(turn.versionIndex, 0)
        XCTAssertEqual(turn.plainText, "only one")
    }

    func testNegativeSelectionClamps() throws {
        let json = """
        { "messages": [
          { "currentlySelected": -3, "versions": [
            { "type": "singleStep", "role": "user", "content": [ { "type": "text", "text": "a" } ] },
            { "type": "singleStep", "role": "user", "content": [ { "type": "text", "text": "b" } ] } ] } ] }
        """
        let turn = try XCTUnwrap(parse(json)?.turns.first)
        XCTAssertEqual(turn.versionIndex, 0)
        XCTAssertEqual(turn.plainText, "a")
    }

    // MARK: - Empty and degenerate files

    func testZeroMessageConversationDecodesWithNoTurns() throws {
        let json = """
        { "name": null, "pinned": false, "createdAt": 0, "tokenCount": 0,
          "systemPrompt": "", "messages": [] }
        """
        let transcript = try XCTUnwrap(parse(json, fileName: "empty.conversation.json"))

        XCTAssertTrue(transcript.turns.isEmpty)
        XCTAssertFalse(transcript.hasExplicitTitle)
        XCTAssertNil(transcript.systemPrompt)   // "" is not a system prompt
        XCTAssertNil(transcript.modelName)
        // A non-numeric stem and a zero `createdAt` leave the file's mtime as
        // the only date there is.
        XCTAssertEqual(transcript.createdAt, modified)
        XCTAssertEqual(transcript.title, AIStorageChatParser.fallbackTitle(for: modified))
    }

    func testMissingMessagesKeyIsNotAnError() throws {
        let transcript = try XCTUnwrap(parse(#"{ "name": "No messages key" }"#))
        XCTAssertEqual(transcript.title, "No messages key")
        XCTAssertTrue(transcript.turns.isEmpty)
    }

    func testNonObjectJSONReturnsNil() {
        XCTAssertNil(parse("[1, 2, 3]"))
        XCTAssertNil(parse("not json at all"))
        XCTAssertNil(AIStorageChatParser.transcript(fromJSON: Data(), fileName: "x.json", modifiedAt: modified))
    }

    func testMessageWithNoVersionsStillYieldsAnEmptyTurn() throws {
        let json = """
        { "messages": [ { "currentlySelected": 0, "versions": [] },
                        { "currentlySelected": 0, "versions": [
                          { "type": "singleStep", "role": "user",
                            "content": [ { "type": "text", "text": "after" } ] } ] } ] }
        """
        let transcript = try XCTUnwrap(parse(json))

        // The interrupted message keeps its slot — dropping it would silently
        // renumber the conversation.
        XCTAssertEqual(transcript.turns.count, 2)
        XCTAssertTrue(transcript.turns[0].isEmpty)
        XCTAssertEqual(transcript.turns[0].role, .unknown)
        XCTAssertEqual(transcript.turns[1].plainText, "after")
    }

    func testNonObjectMessageEntriesAreSkipped() throws {
        let json = """
        { "messages": [ 42, { "currentlySelected": 0, "versions": [
            { "type": "singleStep", "role": "user", "content": [ { "type": "text", "text": "kept" } ] } ] } ] }
        """
        let transcript = try XCTUnwrap(parse(json))
        XCTAssertEqual(transcript.turns.count, 1)
        XCTAssertEqual(transcript.turns[0].plainText, "kept")
    }

    func testWhitespaceOnlyTextPartsAreDropped() throws {
        let json = """
        { "messages": [ { "currentlySelected": 0, "versions": [
            { "type": "singleStep", "role": "user",
              "content": [ { "type": "text", "text": "   \\n  " },
                           { "type": "text", "text": "real" } ] } ] } ] }
        """
        let turn = try XCTUnwrap(parse(json)?.turns.first)
        XCTAssertEqual(turn.bodyParts.count, 1)
        XCTAssertEqual(turn.plainText, "real")
    }

    // MARK: - Unknown schema degradation

    func testUnknownStepTypeIsSurfacedNotDropped() throws {
        let json = """
        { "messages": [ { "currentlySelected": 0, "versions": [
            { "type": "multiStep", "role": "assistant", "steps": [
              { "type": "toolCallRequestBlock", "toolCallRequest": { "name": "search" } },
              { "type": "contentBlock", "content": [ { "type": "text", "text": "answer" } ] } ] } ] } ] }
        """
        let turn = try XCTUnwrap(parse(json)?.turns.first)

        XCTAssertEqual(turn.bodyParts.count, 2)
        guard case .unknown(_, let label) = turn.bodyParts[0] else { return XCTFail("expected unknown part") }
        XCTAssertTrue(label.contains("toolCallRequestBlock"))
        XCTAssertTrue(turn.plainText.contains("answer"))
    }

    func testUnknownContentTypeIsSurfaced() throws {
        let json = """
        { "messages": [ { "currentlySelected": 0, "versions": [
            { "type": "singleStep", "role": "user",
              "content": [ { "type": "audio", "audioIdentifier": "clip.wav" } ] } ] } ] }
        """
        let turn = try XCTUnwrap(parse(json)?.turns.first)
        guard case .unknown(_, let label) = turn.bodyParts.first else { return XCTFail("expected unknown part") }
        XCTAssertTrue(label.contains("audio"))
    }

    func testUnknownVersionTypeStillRendersItsContent() throws {
        let json = """
        { "messages": [ { "currentlySelected": 0, "versions": [
            { "type": "someFutureShape", "role": "user",
              "content": [ { "type": "text", "text": "still readable" } ] } ] } ] }
        """
        let turn = try XCTUnwrap(parse(json)?.turns.first)
        XCTAssertEqual(turn.plainText, "still readable")
    }

    func testUnknownVersionTypeWithNothingUnderstandableIsLabelled() throws {
        let json = """
        { "messages": [ { "currentlySelected": 0, "versions": [
            { "type": "someFutureShape", "role": "assistant", "payload": { "a": 1 } } ] } ] }
        """
        let turn = try XCTUnwrap(parse(json)?.turns.first)
        guard case .unknown(_, let label) = turn.parts.first else { return XCTFail("expected unknown part") }
        XCTAssertTrue(label.contains("someFutureShape"))
    }

    func testNonImageFilePartBecomesAnAttachment() throws {
        let json = """
        { "messages": [ { "currentlySelected": 0, "versions": [
            { "type": "singleStep", "role": "user",
              "content": [ { "type": "file", "fileIdentifier": "notes.pdf",
                             "fileType": "document", "sizeBytes": 41230 } ] } ] } ] }
        """
        let turn = try XCTUnwrap(parse(json)?.turns.first)
        guard case .attachment(_, let identifier, let kind, let bytes) = turn.bodyParts.first else {
            return XCTFail("expected attachment part")
        }
        XCTAssertEqual(identifier, "notes.pdf")
        XCTAssertEqual(kind, "document")
        XCTAssertEqual(bytes, 41_230)
        XCTAssertTrue(try XCTUnwrap(parse(json)).imageIdentifiers.isEmpty)
    }

    func testNonStringDebugInfoIsRenderedAsJSON() throws {
        let json = """
        { "messages": [ { "currentlySelected": 0, "versions": [
            { "type": "multiStep", "role": "assistant", "steps": [
              { "type": "debugInfoBlock", "debugInfo": { "tokens": 12, "cache": "hit" } } ] } ] } ] }
        """
        let turn = try XCTUnwrap(parse(json)?.turns.first)
        guard case .debug(_, let text) = turn.debugParts.first else { return XCTFail("expected debug part") }
        XCTAssertTrue(text.contains("\"tokens\":12"))
        XCTAssertTrue(text.contains("\"cache\":\"hit\""))
    }

    func testDuplicateImageIdentifiersAreDeduplicatedInOrder() throws {
        let json = """
        { "messages": [
          { "currentlySelected": 0, "versions": [ { "type": "singleStep", "role": "user", "content": [
              { "type": "file", "fileIdentifier": "a.png", "fileType": "image", "sizeBytes": 1 },
              { "type": "file", "fileIdentifier": "b.png", "fileType": "image", "sizeBytes": 2 } ] } ] },
          { "currentlySelected": 0, "versions": [ { "type": "singleStep", "role": "user", "content": [
              { "type": "file", "fileIdentifier": "a.png", "fileType": "image", "sizeBytes": 1 } ] } ] } ] }
        """
        let transcript = try XCTUnwrap(parse(json))
        XCTAssertEqual(transcript.imageIdentifiers, ["a.png", "b.png"])
    }

    // MARK: - Dates and titles

    func testStemDateParsesEpochMillisFilename() throws {
        let date = try XCTUnwrap(AIStorageChatParser.stemDate(fileName: "1784921389195.conversation.json"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_784_921_389.195, accuracy: 0.01)
    }

    func testStemDateRejectsNonEpochStems() {
        XCTAssertNil(AIStorageChatParser.stemDate(fileName: "empty.conversation.json"))
        XCTAssertNil(AIStorageChatParser.stemDate(fileName: ".conversation.json"))
        // Numeric, but not plausibly a millisecond timestamp.
        XCTAssertNil(AIStorageChatParser.stemDate(fileName: "42.conversation.json"))
        XCTAssertNil(AIStorageChatParser.stemDate(fileName: "999999999999999.conversation.json"))
    }

    func testFilenameStemBeatsCreatedAt() throws {
        let json = #"{ "createdAt": 1000000000000, "messages": [] }"#
        let transcript = try XCTUnwrap(parse(json, fileName: "1784921389195.conversation.json"))
        XCTAssertEqual(transcript.createdAt?.timeIntervalSince1970 ?? 0, 1_784_921_389.195, accuracy: 0.01)
    }

    func testCreatedAtIsUsedWhenTheStemIsNotADate() throws {
        let json = #"{ "createdAt": 1784921389195, "messages": [] }"#
        let transcript = try XCTUnwrap(parse(json, fileName: "empty.conversation.json"))
        XCTAssertEqual(transcript.createdAt?.timeIntervalSince1970 ?? 0, 1_784_921_389.195, accuracy: 0.01)
    }

    func testFallbackTitleIsAReadableDate() {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 24
        components.hour = 15
        components.minute = 29
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: components)!

        XCTAssertEqual(AIStorageChatParser.fallbackTitle(for: date), "Jul 24, 2026 at 15:29")
        XCTAssertEqual(AIStorageChatParser.monthTitle(for: date), "July 2026")
    }

    func testEmptyNameFallsBackToTheDateTitle() throws {
        let transcript = try XCTUnwrap(parse(#"{ "name": "", "messages": [] }"#))
        XCTAssertFalse(transcript.hasExplicitTitle)
        XCTAssertTrue(transcript.title.contains("2026"))
    }

    // MARK: - Summaries and ordering

    func testSummaryCarriesCountsAndFirstUserLine() throws {
        let transcript = try XCTUnwrap(parse(realistic))
        let summary = AIStorageChatParser.summary(
            for: transcript,
            path: "/home/.lmstudio/conversations/1784921389195.conversation.json",
            displayPath: "~/.lmstudio/conversations/1784921389195.conversation.json",
            fileName: "1784921389195.conversation.json",
            sizeBytes: 38_499,
            modifiedAt: modified
        )

        XCTAssertEqual(summary.title, "Spreadsheet Data Description")
        XCTAssertEqual(summary.turnCount, 2)
        XCTAssertEqual(summary.imageCount, 1)
        XCTAssertTrue(summary.isPinned)
        XCTAssertEqual(summary.modelName, "qwen/qwen3.6-35b-a3b")
        XCTAssertEqual(summary.preview, "Describe Image: 1784921393420 - 431.png")
    }

    func testUnreadableSummaryIsStillListable() {
        let summary = AIStorageChatParser.unreadableSummary(
            path: "/home/.lmstudio/conversations/1784921389195.conversation.json",
            displayPath: "~/.lmstudio/conversations/1784921389195.conversation.json",
            fileName: "1784921389195.conversation.json",
            sizeBytes: 12,
            modifiedAt: modified
        )
        XCTAssertEqual(summary.turnCount, 0)
        XCTAssertFalse(summary.hasExplicitTitle)
        XCTAssertFalse(summary.preview.isEmpty)
    }

    func testNewestFirstPutsPinnedAheadThenSortsByDate() {
        func summary(_ name: String, pinned: Bool, created: TimeInterval) -> AIStorageChatSummary {
            AIStorageChatSummary(path: "/x/\(name)", displayPath: "~/\(name)", fileName: name,
                                 title: name, hasExplicitTitle: true, modelName: nil, turnCount: 0,
                                 imageCount: 0, isPinned: pinned,
                                 createdAt: Date(timeIntervalSince1970: created),
                                 modifiedAt: Date(timeIntervalSince1970: created),
                                 sizeBytes: 0, preview: "")
        }
        let sorted = [
            summary("old", pinned: false, created: 1_000),
            summary("new", pinned: false, created: 3_000),
            summary("pinned-old", pinned: true, created: 500),
        ].sorted(by: AIStorageChatParser.newestFirst)

        XCTAssertEqual(sorted.map(\.fileName), ["pinned-old", "new", "old"])
    }

    // MARK: - Text condensing

    func testCondenseCollapsesWhitespaceAndClips() {
        XCTAssertEqual(AIStorageChatParser.condense("  hello\n\n   world  "), "hello world")
        let long = String(repeating: "word ", count: 200)
        let condensed = AIStorageChatParser.condense(long, limit: 20)
        XCTAssertTrue(condensed.hasSuffix("…"))
        XCTAssertLessThanOrEqual(condensed.count, 21)
    }

    // MARK: - Images

    func testPreviewImageDataDecodesTheSidecar() throws {
        let payload = Data("not really a png, but bytes".utf8).base64EncodedString()
        let json = """
        { "type": "image", "sizeBytes": 100050, "originalName": "image.png",
          "fileIdentifier": "1784921393420 - 431.png",
          "preview": { "data": "data:image/png;base64,\(payload)" } }
        """
        let result = try XCTUnwrap(AIStorageChatParser.previewImageData(fromMetadataJSON: Data(json.utf8)))

        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "not really a png, but bytes")
        XCTAssertEqual(result.originalName, "image.png")
        XCTAssertEqual(result.sizeBytes, 100_050)
    }

    func testSidecarWithoutAPreviewReturnsNil() {
        let json = #"{ "type": "image", "sizeBytes": 10, "originalName": "image.png" }"#
        XCTAssertNil(AIStorageChatParser.previewImageData(fromMetadataJSON: Data(json.utf8)))
        XCTAssertNil(AIStorageChatParser.previewImageData(fromMetadataJSON: Data("garbage".utf8)))
    }

    func testDecodeDataURI() {
        let payload = Data("abc".utf8).base64EncodedString()
        XCTAssertEqual(AIStorageChatParser.decodeDataURI("data:image/png;base64,\(payload)"),
                       Data("abc".utf8))
        XCTAssertNil(AIStorageChatParser.decodeDataURI("data:image/png,\(payload)"))
        XCTAssertNil(AIStorageChatParser.decodeDataURI("https://example.com/a.png"))
        XCTAssertNil(AIStorageChatParser.decodeDataURI("data:image/png;base64"))
    }

    func testSafeFileIdentifiers() {
        XCTAssertTrue(AIStorageChatParser.isSafeFileIdentifier("1784921393420 - 431.png"))
        XCTAssertFalse(AIStorageChatParser.isSafeFileIdentifier(""))
        XCTAssertFalse(AIStorageChatParser.isSafeFileIdentifier("../../.ssh/id_rsa"))
        XCTAssertFalse(AIStorageChatParser.isSafeFileIdentifier("sub/dir.png"))
        XCTAssertFalse(AIStorageChatParser.isSafeFileIdentifier(".."))
    }
}
