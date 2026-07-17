import XCTest
@testable import MacResourceMonitor

final class ProcessCollectorTests: XCTestCase {
    // QA #10: a recycled PID must not reuse the prior CPU-time baseline. The
    // identity keys on (pid, startTime), so two processes sharing a PID but
    // with different start times must produce distinct, non-colliding keys.
    func testProcessIdentityDiffersAcrossPIDReuse() {
        let originalProcess = ProcessIdentity(pid: 4242, startTimeKey: 1_000_000)
        let recycledProcess = ProcessIdentity(pid: 4242, startTimeKey: 2_000_000)

        XCTAssertNotEqual(originalProcess, recycledProcess)
        XCTAssertNotEqual(originalProcess.hashValue, recycledProcess.hashValue)

        var cpuTimeBaselines: [ProcessIdentity: UInt64] = [:]
        cpuTimeBaselines[originalProcess] = 50_000_000_000 // 50s of accumulated CPU time

        // A dictionary keyed only by PID would incorrectly return the dead
        // process's baseline here; keyed by (pid, startTime) it must miss.
        XCTAssertNil(cpuTimeBaselines[recycledProcess])
    }

    func testProcessIdentityEqualForSamePIDAndStartTime() {
        let a = ProcessIdentity(pid: 100, startTimeKey: 555)
        let b = ProcessIdentity(pid: 100, startTimeKey: 555)
        XCTAssertEqual(a, b)
    }
}
