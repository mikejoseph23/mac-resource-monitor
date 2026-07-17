import XCTest
@testable import MacResourceMonitor

final class MemoryCollectorTests: XCTestCase {
    // QA #8: an over-sum across the VM counters must clamp to 0, never
    // underflow-wrap to a multi-exabyte "free" value.
    func testClampedFreeBytesZeroesOnOverSum() {
        let totalBytes: UInt64 = 16_000_000_000
        let usedBytes: UInt64 = 16_500_000_000 // over-sum: exceeds total

        XCTAssertEqual(MemoryCollector.clampedFreeBytes(totalBytes: totalBytes, usedBytes: usedBytes), 0)
    }

    func testClampedFreeBytesComputesNormalDifference() {
        let totalBytes: UInt64 = 16_000_000_000
        let usedBytes: UInt64 = 10_000_000_000

        XCTAssertEqual(MemoryCollector.clampedFreeBytes(totalBytes: totalBytes, usedBytes: usedBytes), 6_000_000_000)
    }

    func testClampedFreeBytesZeroWhenEqual() {
        let bytes: UInt64 = 8_000_000_000
        XCTAssertEqual(MemoryCollector.clampedFreeBytes(totalBytes: bytes, usedBytes: bytes), 0)
    }
}
