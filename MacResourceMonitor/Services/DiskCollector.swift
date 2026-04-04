import Foundation
import IOKit

final class DiskCollector {
    private var previousReadBytes: UInt64 = 0
    private var previousWriteBytes: UInt64 = 0
    private var previousReadOps: UInt64 = 0
    private var previousWriteOps: UInt64 = 0
    private var previousTimestamp: Date?

    func collect() -> DiskMetrics {
        let timestamp = Date()

        // Get disk space via FileManager
        let totalDiskSpace: UInt64
        let usedDiskSpace: UInt64
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: "/")
            let total = (attrs[.systemSize] as? NSNumber)?.uint64Value ?? 0
            let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            totalDiskSpace = total
            usedDiskSpace = total - free
        } catch {
            totalDiskSpace = 0
            usedDiskSpace = 0
        }

        // Get disk I/O stats from IOKit
        var currentRead: UInt64 = 0
        var currentWrite: UInt64 = 0
        var currentReadOps: UInt64 = 0
        var currentWriteOps: UInt64 = 0

        let matchDict = IOServiceMatching("IOBlockStorageDriver")
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)

        if result == KERN_SUCCESS {
            var service = IOIteratorNext(iterator)
            while service != 0 {
                var properties: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = properties?.takeRetainedValue() as? [String: Any] {

                    if let stats = dict["Statistics"] as? [String: Any] {
                        if let readBytes = stats["Bytes (Read)"] as? UInt64 {
                            currentRead += readBytes
                        }
                        if let writeBytes = stats["Bytes (Write)"] as? UInt64 {
                            currentWrite += writeBytes
                        }
                        if let readOps = stats["Operations (Read)"] as? UInt64 {
                            currentReadOps += readOps
                        }
                        if let writeOps = stats["Operations (Write)"] as? UInt64 {
                            currentWriteOps += writeOps
                        }
                    }
                }

                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)
        }

        // Calculate rates
        var readBytesPerSec = 0.0
        var writeBytesPerSec = 0.0
        var readOpsPerSec = 0.0
        var writeOpsPerSec = 0.0

        if let prevTime = previousTimestamp {
            let elapsed = timestamp.timeIntervalSince(prevTime)
            if elapsed > 0 {
                let deltaRead = currentRead >= previousReadBytes ? currentRead - previousReadBytes : 0
                let deltaWrite = currentWrite >= previousWriteBytes ? currentWrite - previousWriteBytes : 0
                readBytesPerSec = Double(deltaRead) / elapsed
                writeBytesPerSec = Double(deltaWrite) / elapsed

                let deltaReadOps = currentReadOps >= previousReadOps ? currentReadOps - previousReadOps : 0
                let deltaWriteOps = currentWriteOps >= previousWriteOps ? currentWriteOps - previousWriteOps : 0
                readOpsPerSec = Double(deltaReadOps) / elapsed
                writeOpsPerSec = Double(deltaWriteOps) / elapsed
            }
        }

        previousReadBytes = currentRead
        previousWriteBytes = currentWrite
        previousReadOps = currentReadOps
        previousWriteOps = currentWriteOps
        previousTimestamp = timestamp

        return DiskMetrics(
            timestamp: timestamp,
            readBytesPerSec: readBytesPerSec,
            writeBytesPerSec: writeBytesPerSec,
            totalDiskSpace: totalDiskSpace,
            usedDiskSpace: usedDiskSpace,
            totalReadBytes: currentRead,
            totalWriteBytes: currentWrite,
            readOpsPerSec: readOpsPerSec,
            writeOpsPerSec: writeOpsPerSec
        )
    }
}
