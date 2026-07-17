import XCTest
@testable import MacResourceMonitor

final class GPUCollectorTests: XCTestCase {
    // QA #6/#7: IORegistry integer properties bridge to Swift as NSNumber,
    // not Int — an `as? Int` cast silently fails and falls through to the
    // hardcoded default. Assert the NSNumber path recovers the real value.
    func testParseAcceleratorStatsReadsCoreCountFromNSNumber() {
        let perfStats: [String: Any] = [
            "GPU Activity(%)": NSNumber(value: 42.5),
            "GPU Core Count": NSNumber(value: 80),
        ]

        let parsed = GPUCollector.parseAcceleratorStats(perfStats: perfStats, topLevelDict: [:])

        XCTAssertEqual(parsed.coreCount, 80)
        XCTAssertEqual(parsed.utilization, 42.5, accuracy: 0.001)
    }

    func testParseAcceleratorStatsFallsBackToTopLevelCoreCountKey() {
        let perfStats: [String: Any] = ["Device Utilization %": NSNumber(value: 10.0)]
        let topLevelDict: [String: Any] = ["gpu-core-count": NSNumber(value: 40)]

        let parsed = GPUCollector.parseAcceleratorStats(perfStats: perfStats, topLevelDict: topLevelDict)

        XCTAssertEqual(parsed.coreCount, 40)
        XCTAssertEqual(parsed.utilization, 10.0, accuracy: 0.001)
    }

    func testParseAcceleratorStatsDefaultsToZeroWhenKeysMissing() {
        let parsed = GPUCollector.parseAcceleratorStats(perfStats: [:], topLevelDict: [:])

        XCTAssertEqual(parsed.coreCount, 0)
        XCTAssertEqual(parsed.utilization, 0.0, accuracy: 0.001)
    }
}
