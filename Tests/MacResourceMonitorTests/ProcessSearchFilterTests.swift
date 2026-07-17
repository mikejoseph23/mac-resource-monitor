import XCTest
@testable import MacResourceMonitor

final class ProcessSearchFilterTests: XCTestCase {
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

    func testEmptyQueryReturnsAll() {
        let procs = [leaf(1, "Safari"), leaf(2, "Finder")]
        XCTAssertEqual(ProcessSearchFilter.apply(procs, query: "").count, 2)
        XCTAssertEqual(ProcessSearchFilter.apply(procs, query: "   ").count, 2)
    }

    func testNameMatchIsCaseInsensitiveSubstring() {
        let procs = [leaf(1, "Safari"), leaf(2, "Finder")]
        let result = ProcessSearchFilter.apply(procs, query: "saf")
        XCTAssertEqual(result.map(\.name), ["Safari"])
    }

    func testPIDMatch() {
        let procs = [leaf(4242, "Safari"), leaf(99, "Finder")]
        let result = ProcessSearchFilter.apply(procs, query: "4242")
        XCTAssertEqual(result.map(\.pid), [4242])
    }

    func testNoMatchReturnsEmpty() {
        let procs = [leaf(1, "Safari"), leaf(2, "Finder")]
        XCTAssertTrue(ProcessSearchFilter.apply(procs, query: "zzz").isEmpty)
    }

    func testGroupSurvivesWhenGroupNameMatches() {
        let g = group(10, "Chrome", [leaf(11, "Chrome Helper"), leaf(12, "GPU Process")])
        let result = ProcessSearchFilter.apply([g], query: "chrome")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].children.count, 2, "Group-name match keeps all children")
    }

    func testGroupNarrowsToMatchingChildren() {
        let child1 = leaf(11, "Web Content")
        let child2 = leaf(12, "GPU Process")
        let g = group(10, "Chrome", [child1, child2])
        let result = ProcessSearchFilter.apply([g], query: "gpu")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].children.map(\.name), ["GPU Process"])
    }

    func testGroupChildPIDMatchNarrows() {
        let g = group(10, "Chrome", [leaf(11, "Web Content"), leaf(2222, "GPU Process")])
        let result = ProcessSearchFilter.apply([g], query: "2222")
        XCTAssertEqual(result.first?.children.map(\.pid), [2222])
    }
}
