import XCTest
@testable import MacResourceMonitor

final class MetricSeverityTests: XCTestCase {
    func testUtilizationThresholds() {
        XCTAssertEqual(MetricSeverity.utilization(69.9), .normal)
        XCTAssertEqual(MetricSeverity.utilization(70), .warning)
        XCTAssertEqual(MetricSeverity.utilization(89.9), .warning)
        XCTAssertEqual(MetricSeverity.utilization(90), .critical)
    }

    func testCapacityThresholds() {
        XCTAssertEqual(MetricSeverity.capacity(79.9), .normal)
        XCTAssertEqual(MetricSeverity.capacity(80), .warning)
        XCTAssertEqual(MetricSeverity.capacity(94.9), .warning)
        XCTAssertEqual(MetricSeverity.capacity(95), .critical)
    }

    func testProcessLoadThresholds() {
        XCTAssertEqual(MetricSeverity.processLoad(39.9), .normal)
        XCTAssertEqual(MetricSeverity.processLoad(40), .warning)
        XCTAssertEqual(MetricSeverity.processLoad(79.9), .warning)
        XCTAssertEqual(MetricSeverity.processLoad(80), .critical)
    }
}
