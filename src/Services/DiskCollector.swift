import Foundation
import IOKit

final class DiskCollector {
    private var previousReadBytes: UInt64 = 0
    private var previousWriteBytes: UInt64 = 0
    private var previousReadOps: UInt64 = 0
    private var previousWriteOps: UInt64 = 0
    private var previousTimestamp: Date?

    /// Paths that represent system/internal volumes not useful to display.
    private static let excludedPrefixes = [
        "/System/Volumes/",
        "/Library/Developer/CoreSimulator/",
    ]

    func collect() -> DiskMetrics {
        let timestamp = Date()

        // Enumerate user-visible volumes
        let volumes = collectVolumes()

        // Boot volume space (for top-level gauge and backward compat)
        let bootVolume = volumes.first(where: \.isBootVolume)
        let totalDiskSpace = bootVolume?.totalBytes ?? 0
        let usedDiskSpace = bootVolume?.usedBytes ?? 0

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
            writeOpsPerSec: writeOpsPerSec,
            volumes: volumes
        )
    }

    private func collectVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsBrowsableKey, .volumeIsLocalKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return [] }

        return urls.compactMap { url in
            let path = url.path
            let isBoot = path == "/"

            // Filter out system/internal pseudo-volumes.
            if Self.excludedPrefixes.contains(where: { path.hasPrefix($0) }) { return nil }

            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let name = values.volumeName,
                  let total = values.volumeTotalCapacity,
                  let available = values.volumeAvailableCapacity,
                  total > 0 else { return nil }

            // Keep the boot volume unconditionally; otherwise only surface real,
            // user-relevant drives. This filters out mounted disk images (DMGs —
            // e.g. launching the app from its own .dmg), read-only images, and
            // other non-physical mounts that shouldn't read as "storage".
            if !isBoot {
                // Must be a local, Finder-browsable volume (drops network
                // auto-mounts and hidden pseudo-volumes).
                if values.volumeIsBrowsable == false { return nil }
                if values.volumeIsLocal == false { return nil }
                // Read-only or non-browsable at the mount level → disk image /
                // system snapshot, not a drive the user manages.
                if Self.isDiskImageOrReadOnly(path: path) { return nil }
            }

            return VolumeInfo(
                name: name,
                mountPoint: path,
                totalBytes: UInt64(total),
                usedBytes: UInt64(total - available),
                isBootVolume: isBoot
            )
        }
    }

    /// Inspects the mount flags via `statfs`. A mounted DMG is read-only
    /// (`MNT_RDONLY`); other pseudo-mounts set `MNT_DONTBROWSE`. Either marks a
    /// volume we don't want in the Storage list. Returns false if the mount
    /// can't be statted (fail open — real drives always stat cleanly).
    private static func isDiskImageOrReadOnly(path: String) -> Bool {
        var buf = statfs()
        guard statfs(path, &buf) == 0 else { return false }
        let flags = buf.f_flags
        if flags & UInt32(MNT_RDONLY) != 0 { return true }
        if flags & UInt32(MNT_DONTBROWSE) != 0 { return true }
        return false
    }
}
