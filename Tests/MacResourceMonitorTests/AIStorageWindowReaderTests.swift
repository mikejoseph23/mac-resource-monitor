import XCTest
@testable import MacResourceMonitor

/// Window math for the log viewer's scroll-up paging: `sliceWindow` is what
/// keeps a pathological multi-GB log bounded, so the offsets it reports have to
/// be exact — the viewer feeds `startOffset` straight back in as the next
/// window's `endOffset`, and an off-by-one there either loses a line or repeats
/// one on every page.
final class AIStorageWindowReaderTests: XCTestCase {
    private let lines = (0..<200).map { String(format: "line-%03d\n", $0) }

    private var content: String { lines.joined() }
    private var data: Data { Data(content.utf8) }

    func testWholePrefixWhenLimitCoversEverything() {
        let end = data.count
        let result = AIStorageTailReader.sliceWindow(data, endOffset: end, limit: end)
        XCTAssertEqual(result.startOffset, 0)
        XCTAssertEqual(result.text, content)
    }

    func testWindowStartsOnALineBoundary() {
        let result = AIStorageTailReader.sliceWindow(data, endOffset: data.count, limit: 55)
        XCTAssertGreaterThan(result.startOffset, 0)
        XCTAssertTrue(result.text.hasPrefix("line-"), "window must not start mid-line")
        XCTAssertTrue(content.hasSuffix(result.text))
        XCTAssertLessThanOrEqual(result.text.utf8.count, 55)
    }

    func testStartOffsetIsTheByteIndexOfTheReturnedText() {
        let result = AIStorageTailReader.sliceWindow(data, endOffset: data.count, limit: 300)
        let expected = String(decoding: data[result.startOffset...], as: UTF8.self)
        XCTAssertEqual(result.text, expected)
    }

    /// Paging: feeding one window's `startOffset` back in as the next window's
    /// `endOffset` must reconstruct the file exactly, with no gap or overlap.
    func testSuccessiveWindowsReassembleTheFile() {
        var assembled = ""
        var end = data.count
        var guardCount = 0

        while end > 0 {
            let window = AIStorageTailReader.sliceWindow(data, endOffset: end, limit: 64)
            XCTAssertFalse(window.text.isEmpty, "a non-empty prefix must always yield bytes")
            XCTAssertLessThan(window.startOffset, end)
            assembled = window.text + assembled
            end = window.startOffset

            guardCount += 1
            XCTAssertLessThan(guardCount, 1_000, "paging failed to terminate")
        }

        XCTAssertEqual(assembled, content)
    }

    func testTailThenPageUpCoversTheWholeFile() {
        let tail = AIStorageTailReader.sliceTail(data, limit: 200)
        XCTAssertTrue(tail.truncated)
        XCTAssertGreaterThan(tail.startOffset, 0)

        let earlier = AIStorageTailReader.sliceWindow(data, endOffset: tail.startOffset, limit: data.count)
        XCTAssertEqual(earlier.startOffset, 0)
        XCTAssertEqual(earlier.text + tail.text, content)
    }

    func testNoNewlineInWindowFallsBackToTheRawCut() {
        let oneLine = Data(String(repeating: "x", count: 500).utf8)
        let result = AIStorageTailReader.sliceWindow(oneLine, endOffset: 500, limit: 100)
        XCTAssertEqual(result.startOffset, 400)
        XCTAssertEqual(result.text.count, 100)
    }

    func testDegenerateOffsetsAreClamped() {
        XCTAssertEqual(AIStorageTailReader.sliceWindow(data, endOffset: 0, limit: 100).text, "")
        XCTAssertEqual(AIStorageTailReader.sliceWindow(data, endOffset: -5, limit: 100).text, "")
        XCTAssertEqual(AIStorageTailReader.sliceWindow(data, endOffset: 100, limit: 0).text, "")
        XCTAssertEqual(AIStorageTailReader.sliceWindow(data, endOffset: 100, limit: -3).text, "")
        XCTAssertEqual(AIStorageTailReader.sliceWindow(Data(), endOffset: 10, limit: 10).text, "")

        // An `endOffset` past the end clamps to the end rather than trapping.
        let past = AIStorageTailReader.sliceWindow(data, endOffset: data.count + 1_000, limit: data.count)
        XCTAssertEqual(past.text, content)
        XCTAssertEqual(past.startOffset, 0)
    }

    /// `Data` slices don't start at index 0; the offsets must stay relative to
    /// the slice, not the buffer it came from.
    func testWorksOnANonZeroBasedDataSlice() {
        let slice = data[10...]
        let result = AIStorageTailReader.sliceWindow(slice, endOffset: slice.count, limit: 40)
        XCTAssertTrue(content.hasSuffix(result.text))
        XCTAssertEqual(result.text, String(decoding: slice[(slice.startIndex + result.startOffset)...], as: UTF8.self))
    }
}
