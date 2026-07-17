import XCTest
import Darwin
@testable import MacResourceMonitor

final class NetworkCollectorTests: XCTestCase {
    // QA #4: the sysctl NET_RT_IFLIST2 buffer gives no 8-byte alignment
    // guarantee for the if_msghdr2 records it contains, so parsing must use
    // loadUnaligned instead of a typed load. Build a synthetic buffer with a
    // deliberate one-byte pad before the record (forcing a misaligned start)
    // and confirm the counters still come back correct.
    func testParseIFList2BufferReadsUnalignedCounters() {
        var msg = if_msghdr2()
        msg.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        msg.ifm_version = 0
        msg.ifm_type = UInt8(RTM_IFINFO2)
        msg.ifm_addrs = 0
        msg.ifm_flags = 0
        msg.ifm_index = 1
        msg.ifm_snd_len = 0
        msg.ifm_snd_maxlen = 0
        msg.ifm_snd_drops = 0
        msg.ifm_timer = 0
        msg.ifm_data.ifi_ibytes = 123_456_789_012
        msg.ifm_data.ifi_obytes = 987_654_321_098
        msg.ifm_data.ifi_ipackets = 42
        msg.ifm_data.ifi_opackets = 24

        // A leading 4-byte filler record (msgType != RTM_IFINFO2, so it's
        // skipped) shifts the real record to buffer offset 4 — not 8-byte
        // aligned — so the if_data64 64-bit fields inside it can only be
        // read correctly via loadUnaligned, exercising the QA #4 fix.
        var buffer: [UInt8] = [4, 0, 0, 0]
        withUnsafeBytes(of: &msg) { rawMsg in
            buffer.append(contentsOf: rawMsg)
        }

        let stats = NetworkCollector.parseIFList2Buffer(buffer)

        XCTAssertEqual(stats.bytesIn, 123_456_789_012)
        XCTAssertEqual(stats.bytesOut, 987_654_321_098)
        XCTAssertEqual(stats.packetsIn, 42)
        XCTAssertEqual(stats.packetsOut, 24)
    }

    func testParseIFList2BufferSkipsLoopbackInterface() {
        var msg = if_msghdr2()
        msg.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        msg.ifm_type = UInt8(RTM_IFINFO2)
        msg.ifm_flags = Int32(IFF_LOOPBACK)
        msg.ifm_data.ifi_ibytes = 999
        msg.ifm_data.ifi_obytes = 999
        msg.ifm_data.ifi_ipackets = 9
        msg.ifm_data.ifi_opackets = 9

        var buffer = [UInt8]()
        withUnsafeBytes(of: &msg) { rawMsg in
            buffer.append(contentsOf: rawMsg)
        }

        let stats = NetworkCollector.parseIFList2Buffer(buffer)

        XCTAssertEqual(stats.bytesIn, 0)
        XCTAssertEqual(stats.bytesOut, 0)
        XCTAssertEqual(stats.packetsIn, 0)
        XCTAssertEqual(stats.packetsOut, 0)
    }

    func testParseIFList2BufferHandlesEmptyBuffer() {
        let stats = NetworkCollector.parseIFList2Buffer([])
        XCTAssertEqual(stats.bytesIn, 0)
        XCTAssertEqual(stats.bytesOut, 0)
    }
}
