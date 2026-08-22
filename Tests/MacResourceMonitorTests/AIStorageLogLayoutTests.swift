import XCTest
@testable import MacResourceMonitor

final class AIStorageLogLayoutTests: XCTestCase {
    private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(identifier: "UTC")
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(from: components)!
    }

    private func entry(_ name: String, _ modifiedAt: Date) -> AIStorageFileEntry {
        AIStorageFileEntry(name: name, path: "/x/\(name)", displayPath: "~/x/\(name)",
                            relativePath: name, sizeBytes: 1, modifiedAt: modifiedAt,
                            monthSection: nil)
    }

    // MARK: - monthSection(for:)

    func testMonthSectionFormatsYearMonth() {
        XCTAssertEqual(AIStorageLogLayout.monthSection(for: utcDate(2026, 8, 22)), "2026-08")
    }

    func testMonthSectionYearStartBoundary() {
        XCTAssertEqual(AIStorageLogLayout.monthSection(for: utcDate(2026, 1, 1)), "2026-01")
    }

    func testMonthSectionYearEndBoundary() {
        XCTAssertEqual(AIStorageLogLayout.monthSection(for: utcDate(2026, 12, 31)), "2026-12")
    }

    func testMonthSectionIsLocaleIndependent() {
        let date = utcDate(2026, 8, 22)
        let expected = AIStorageLogLayout.monthSection(for: date)

        let originalLocale = Locale.current
        // Exercise a non-Gregorian, non-English locale to prove the formatter
        // doesn't leak the current process locale into the result.
        let arabicLocale = Locale(identifier: "ar_SA@calendar=islamic-civil")
        XCTAssertNotEqual(originalLocale.identifier, arabicLocale.identifier)

        XCTAssertEqual(AIStorageLogLayout.monthSection(for: date), expected)
        XCTAssertEqual(AIStorageLogLayout.monthSection(for: date), "2026-08")
    }

    // MARK: - newestFirst(_:_:)

    func testNewestFirstOrdersByDateDescending() {
        let older = entry("a.log", utcDate(2026, 8, 1))
        let newer = entry("b.log", utcDate(2026, 8, 2))
        XCTAssertTrue(AIStorageLogLayout.newestFirst(newer, older))
        XCTAssertFalse(AIStorageLogLayout.newestFirst(older, newer))
    }

    func testNewestFirstTiebreaksByNameDescending() {
        let date = utcDate(2026, 8, 22)
        let higherName = entry("z.log", date)
        let lowerName = entry("a.log", date)
        XCTAssertTrue(AIStorageLogLayout.newestFirst(higherName, lowerName))
        XCTAssertFalse(AIStorageLogLayout.newestFirst(lowerName, higherName))
    }

    func testNewestFirstSortsMixedList() {
        let entries = [
            entry("2026-08-20.log", utcDate(2026, 8, 20)),
            entry("2026-08-22-b.log", utcDate(2026, 8, 22)),
            entry("2026-08-22-a.log", utcDate(2026, 8, 22)),
            entry("2026-08-21.log", utcDate(2026, 8, 21)),
        ]
        let sorted = entries.sorted(by: AIStorageLogLayout.newestFirst)
        XCTAssertEqual(sorted.map(\.name), [
            "2026-08-22-b.log",
            "2026-08-22-a.log",
            "2026-08-21.log",
            "2026-08-20.log",
        ])
    }
}
