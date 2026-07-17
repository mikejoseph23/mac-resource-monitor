import Foundation
import Darwin

final class NetworkCollector {
    private var previousBytesIn: UInt64 = 0
    private var previousBytesOut: UInt64 = 0
    private var previousPacketsIn: UInt64 = 0
    private var previousPacketsOut: UInt64 = 0
    private var previousTimestamp: Date?

    func collect() -> NetworkMetrics {
        let timestamp = Date()

        let stats = readNetworkStats()
        let currentIn = stats.bytesIn
        let currentOut = stats.bytesOut
        let currentPacketsIn = stats.packetsIn
        let currentPacketsOut = stats.packetsOut

        // Calculate rates
        var bytesInPerSec = 0.0
        var bytesOutPerSec = 0.0
        var packetsInPerSec = 0.0
        var packetsOutPerSec = 0.0

        if let prevTime = previousTimestamp {
            let elapsed = timestamp.timeIntervalSince(prevTime)
            if elapsed > 0 {
                let deltaIn = currentIn >= previousBytesIn ? currentIn - previousBytesIn : 0
                let deltaOut = currentOut >= previousBytesOut ? currentOut - previousBytesOut : 0
                bytesInPerSec = Double(deltaIn) / elapsed
                bytesOutPerSec = Double(deltaOut) / elapsed

                let deltaPktsIn = currentPacketsIn >= previousPacketsIn ? currentPacketsIn - previousPacketsIn : 0
                let deltaPktsOut = currentPacketsOut >= previousPacketsOut ? currentPacketsOut - previousPacketsOut : 0
                packetsInPerSec = Double(deltaPktsIn) / elapsed
                packetsOutPerSec = Double(deltaPktsOut) / elapsed
            }
        }

        previousBytesIn = currentIn
        previousBytesOut = currentOut
        previousPacketsIn = currentPacketsIn
        previousPacketsOut = currentPacketsOut
        previousTimestamp = timestamp

        return NetworkMetrics(
            timestamp: timestamp,
            bytesInPerSec: bytesInPerSec,
            bytesOutPerSec: bytesOutPerSec,
            totalBytesIn: currentIn,
            totalBytesOut: currentOut,
            packetsInPerSec: packetsInPerSec,
            packetsOutPerSec: packetsOutPerSec
        )
    }

    private struct NetworkStats {
        let bytesIn: UInt64
        let bytesOut: UInt64
        let packetsIn: UInt64
        let packetsOut: UInt64
    }

    /// Read cumulative network stats using sysctl NET_RT_IFLIST2.
    /// This provides 64-bit counters via if_msghdr2, unlike getifaddrs
    /// which exposes 32-bit ifi_ibytes/ifi_obytes that can silently
    /// wrap around or read as zero on modern macOS.
    private func readNetworkStats() -> NetworkStats {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: size_t = 0

        // First call: get required buffer size
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else {
            return NetworkStats(bytesIn: 0, bytesOut: 0, packetsIn: 0, packetsOut: 0)
        }

        var buf = [UInt8](repeating: 0, count: len)

        // Second call: fill buffer
        guard sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 else {
            return NetworkStats(bytesIn: 0, bytesOut: 0, packetsIn: 0, packetsOut: 0)
        }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var totalPacketsIn: UInt64 = 0
        var totalPacketsOut: UInt64 = 0

        // Do ALL reads inside the closure — a raw pointer must not escape
        // withUnsafeBytes (its buffer is only valid for the closure's lifetime).
        // The sysctl buffer offers no 8-byte alignment guarantee, so every
        // struct read uses loadUnaligned(fromByteOffset:as:).
        buf.withUnsafeBytes { rawBuf in
            var offset = 0
            while offset + MemoryLayout<UInt16>.size <= len {
                // Each record starts with an if_msghdr2 (or rt_msghdr variant).
                let msgLen = Int(rawBuf.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) // ifm_msglen
                guard msgLen > 0, offset + msgLen <= len else { break }

                // ifm_type is at byte offset 3 (after ifm_msglen:u16, ifm_version:u8)
                let msgType = rawBuf.loadUnaligned(fromByteOffset: offset + 3, as: UInt8.self)

                if msgType == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let ifm2 = rawBuf.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)

                    // Skip loopback (IFF_LOOPBACK = 0x8)
                    if UInt32(bitPattern: ifm2.ifm_flags) & UInt32(IFF_LOOPBACK) == 0 {
                        totalIn += ifm2.ifm_data.ifi_ibytes
                        totalOut += ifm2.ifm_data.ifi_obytes
                        totalPacketsIn += UInt64(ifm2.ifm_data.ifi_ipackets)
                        totalPacketsOut += UInt64(ifm2.ifm_data.ifi_opackets)
                    }
                }

                offset += msgLen
            }
        }

        return NetworkStats(bytesIn: totalIn, bytesOut: totalOut, packetsIn: totalPacketsIn, packetsOut: totalPacketsOut)
    }
}
