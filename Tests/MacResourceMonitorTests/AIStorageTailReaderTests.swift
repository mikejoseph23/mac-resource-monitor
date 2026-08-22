import XCTest
@testable import MacResourceMonitor

final class AIStorageTailReaderTests: XCTestCase {
    func testEmptyData() {
        let result = AIStorageTailReader.sliceTail(Data(), limit: 1024)
        XCTAssertEqual(result.text, "")
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.totalBytes, 0)
    }

    func testSmallFileUnderLimitIsNotTruncated() {
        let data = Data("line one\nline two\nline three\n".utf8)
        let result = AIStorageTailReader.sliceTail(data, limit: 1024)
        XCTAssertEqual(result.text, "line one\nline two\nline three\n")
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.totalBytes, data.count)
    }

    func testLargeFileOverLimitIsTruncated() {
        // 5 lines of 10 bytes each ("0123456789\n" is 11 bytes); with a small
        // limit only the trailing lines survive.
        let lines = (0..<50).map { String(format: "line-%03d\n", $0) }
        let data = Data(lines.joined().utf8)
        let result = AIStorageTailReader.sliceTail(data, limit: 50)

        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.totalBytes, data.count)
        XCTAssertTrue(data.count > 50)
        // Returned text must be a suffix of the original content.
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasSuffix(result.text))
        XCTAssertFalse(result.text.isEmpty)
    }

    func testFirstVisibleLineIsNotTornWhenCutLandsMidLine() {
        // Craft data where a fixed byte-offset cut deliberately lands inside a
        // line, so the aligned result must start exactly at the next newline.
        let data = Data("AAAAAAAAAA\nBBBBBBBBBB\nCCCCCCCCCC\n".utf8)
        // limit = 15 cuts 15 bytes from the end, landing inside "BBBBBBBBBB\n"
        // (the tail is "BBBBB\nCCCCCCCCCC\n", cutting mid "BBBBBBBBBB").
        let result = AIStorageTailReader.sliceTail(data, limit: 15)

        XCTAssertTrue(result.truncated)
        // The aligned text must not begin with a torn fragment of "BBBBBBBBBB";
        // it should start at a full line boundary.
        XCTAssertFalse(result.text.hasPrefix("BBBBB"))
        XCTAssertTrue(result.text == "CCCCCCCCCC\n" || result.text.hasPrefix("BBBBBBBBBB\n"))
        // Every line in the result is a complete line from the source, i.e.
        // the result is a suffix of the source starting right after a "\n".
        let fullText = String(decoding: data, as: UTF8.self)
        if let range = fullText.range(of: result.text), !result.text.isEmpty {
            let precedingIndex = fullText.index(before: range.lowerBound)
            XCTAssertTrue(range.lowerBound == fullText.startIndex || fullText[precedingIndex] == "\n")
        }
    }

    func testNoNewlineInTailFallsBackToRawCut() {
        // One giant line with no newline anywhere in the tail window: there's
        // nothing to align to, so the raw cut is returned rather than an
        // empty slice.
        let data = Data(String(repeating: "X", count: 100).utf8)
        let result = AIStorageTailReader.sliceTail(data, limit: 10)

        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.totalBytes, 100)
        XCTAssertEqual(result.text, String(repeating: "X", count: 10))
    }

    func testNonUTF8ByteAtCutBoundaryDecodesLossyWithoutThrowing() {
        // 0xFF/0xFE are not valid UTF-8 lead bytes. Place them inside a
        // no-newline window so the raw cut (not newline-aligned) lands right
        // on top of them, proving decoding is lossy and never throws/traps.
        var bytes = Array("headertext".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE])
        bytes.append(contentsOf: Array("tailtext".utf8))
        let data = Data(bytes)

        let result = AIStorageTailReader.sliceTail(data, limit: 15)

        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.totalBytes, data.count)
        // Lossy decoding replaces invalid bytes with U+FFFD rather than
        // throwing or crashing; the call completing at all is the assertion.
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertTrue(result.text.hasSuffix("tailtext"))
    }
}
