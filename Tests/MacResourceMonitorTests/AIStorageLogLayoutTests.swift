import XCTest
@testable import MacResourceMonitor

/// Scaffolding only — T1 fills this in with the full accept/deny matrix and
/// edge cases from the planning document. These smoke cases just prove the
/// pure helpers compile and behave sanely.
final class AIStorageLogLayoutTests: XCTestCase {
    func testMonthSectionFormatsYearMonth() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 22
        components.timeZone = TimeZone(identifier: "UTC")
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: components)!
        XCTAssertEqual(AIStorageLogLayout.monthSection(for: date), "2026-08")
    }

    func testPathGuardAcceptsExplorableTargets() {
        let home = "/Users/mike"
        XCTAssertTrue(AIStoragePathGuard.isReadable(
            path: "\(home)/.lmstudio/server-logs/2026-08/x.log", homePath: home))
        XCTAssertTrue(AIStoragePathGuard.isReadable(
            path: "\(home)/.omlx/logs/server.log", homePath: home))
    }

    func testPathGuardDeniesNeverTouchPaths() {
        let home = "/Users/mike"
        XCTAssertFalse(AIStoragePathGuard.isReadable(
            path: "\(home)/.lmstudio/models/some-model.gguf", homePath: home))
        XCTAssertFalse(AIStoragePathGuard.isReadable(
            path: "\(home)/.omlx/settings.json", homePath: home))
        XCTAssertFalse(AIStoragePathGuard.isReadable(
            path: "\(home)/.lmstudio", homePath: home))
    }

    func testTailReaderSmallFileNotTruncated() {
        let data = Data("hello\nworld\n".utf8)
        let result = AIStorageTailReader.sliceTail(data, limit: 1024)
        XCTAssertEqual(result.text, "hello\nworld\n")
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.totalBytes, data.count)
    }

    func testTailReaderEmptyData() {
        let result = AIStorageTailReader.sliceTail(Data(), limit: 1024)
        XCTAssertEqual(result.text, "")
        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.totalBytes, 0)
    }
}
