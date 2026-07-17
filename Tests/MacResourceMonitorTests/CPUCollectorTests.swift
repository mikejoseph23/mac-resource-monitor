import XCTest
@testable import MacResourceMonitor

final class CPUCollectorTests: XCTestCase {
    // QA #2: a per-core tick counter is unsigned but exposed as Int32 by the
    // kernel API. Once it passes 2³¹ it reads as a negative Int32; a plain
    // UInt64(_:) cast on that negative value traps. Reinterpreting the bit
    // pattern as UInt32 first must recover the true unsigned value instead.
    func testUnsignedTicksRecoversValueNearInt32Overflow() {
        // 2³¹ itself: as Int32 this is Int32.min (-2147483648).
        let atOverflow = Int32(bitPattern: UInt32(1 << 31))
        XCTAssertEqual(CPUCollector.unsignedTicks(from: atOverflow), UInt64(1) << 31)

        // Comfortably over 2³¹: 3,000,000,000 wraps to a negative Int32.
        let overOverflowRaw: UInt32 = 3_000_000_000
        let overOverflow = Int32(bitPattern: overOverflowRaw)
        XCTAssertLessThan(overOverflow, 0, "sanity check: value should read negative as Int32")
        XCTAssertEqual(CPUCollector.unsignedTicks(from: overOverflow), UInt64(overOverflowRaw))

        // Sub-2³¹ values must still round-trip unchanged.
        let underOverflow: Int32 = 12_345
        XCTAssertEqual(CPUCollector.unsignedTicks(from: underOverflow), 12_345)
    }

    // QA #5: current < previous means the 32-bit kernel counter wrapped.
    // The delta must be zeroed, never computed as an underflowing subtraction.
    func testTickDeltaZeroesOnWrap() {
        let previous: UInt64 = UInt64(UInt32.max) - 10
        let current: UInt64 = 5 // wrapped past UInt32.max and restarted low

        XCTAssertEqual(CPUCollector.tickDelta(current: current, previous: previous), 0)
    }

    func testTickDeltaComputesNormalIncrease() {
        XCTAssertEqual(CPUCollector.tickDelta(current: 1_500, previous: 1_000), 500)
    }

    func testTickDeltaZeroWhenUnchanged() {
        XCTAssertEqual(CPUCollector.tickDelta(current: 1_000, previous: 1_000), 0)
    }
}
