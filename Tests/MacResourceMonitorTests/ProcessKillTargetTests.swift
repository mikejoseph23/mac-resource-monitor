import XCTest
@testable import MacResourceMonitor

final class ProcessKillTargetTests: XCTestCase {
    private func leaf(_ pid: Int32, _ name: String) -> ProcessMetrics {
        ProcessMetrics(pid: pid, name: name, user: "mike", bundleIdentifier: nil,
                       cpuUsage: 1, memoryBytes: 1, isGroup: false, children: [])
    }

    private func group(_ pid: Int32, _ name: String, _ children: [ProcessMetrics]) -> ProcessMetrics {
        ProcessMetrics(pid: pid, name: name, user: "mike", bundleIdentifier: nil,
                       cpuUsage: children.reduce(0) { $0 + $1.cpuUsage },
                       memoryBytes: children.reduce(0) { $0 + $1.memoryBytes },
                       isGroup: true, children: children)
    }

    func testLeafPIDsIsJustItself() {
        let p = leaf(42, "Safari")
        XCTAssertEqual(ProcessKillTarget.pids(for: p), [42])
    }

    func testGroupPIDsIsAllChildren() {
        let g = group(10, "Chrome", [leaf(11, "Chrome Helper"), leaf(12, "GPU Process")])
        XCTAssertEqual(ProcessKillTarget.pids(for: g), [11, 12])
    }

    func testZeroPIDsAreFilteredOut() {
        let g = group(0, "System Services", [leaf(0, "kernel_task"), leaf(99, "launchd")])
        XCTAssertEqual(ProcessKillTarget.pids(for: g), [99])
    }

    func testLeafScopeLabelIsJustName() {
        XCTAssertEqual(ProcessKillTarget.scopeLabel(for: leaf(42, "Safari")), "Safari")
    }

    func testGroupScopeLabelIncludesProcessCount() {
        let g = group(10, "Chrome", [leaf(11, "Chrome Helper"), leaf(12, "GPU Process")])
        XCTAssertEqual(ProcessKillTarget.scopeLabel(for: g), "Chrome (2 processes)")
    }
}
