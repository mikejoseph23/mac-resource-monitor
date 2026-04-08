import SwiftUI

struct VolumesPanelView: View {
    let volumes: [VolumeInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                Text("Storage Volumes")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(volumes.count) volume\(volumes.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            VStack(spacing: 10) {
                ForEach(volumes) { volume in
                    volumeRow(volume)
                }
            }
            .padding(14)
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        }
    }

    private func volumeRow(_ volume: VolumeInfo) -> some View {
        let severity = MetricSeverity.from(percent: volume.usagePercent, warningAt: 80, criticalAt: 95)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: volume.isBootVolume ? "internaldrive.fill" : "externaldrive")
                    .font(.system(size: 12))
                    .foregroundStyle(severity.color)
                    .frame(width: 16)

                Text(volume.name)
                    .font(.system(size: 12, weight: .medium))

                if volume.isBootVolume {
                    Text("Boot")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(severity.color.opacity(0.7)))
                }

                Spacer()

                Text(String(format: "%.0f%%", volume.usagePercent))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(severity.color)
            }

            // Usage bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(severity.color.opacity(0.7))
                        .frame(width: geometry.size.width * min(CGFloat(volume.usagePercent / 100.0), 1.0))
                }
            }
            .frame(height: 6)

            HStack {
                Text("\(formatBytes(volume.usedBytes)) used")
                Spacer()
                Text("\(formatBytes(volume.freeBytes)) free of \(formatBytes(volume.totalBytes))")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let tb = Double(bytes) / (1024 * 1024 * 1024 * 1024)
        if tb >= 1.0 {
            return String(format: "%.1f TB", tb)
        }
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }
}

#Preview {
    VolumesPanelView(volumes: [
        VolumeInfo(name: "Macintosh HD", mountPoint: "/", totalBytes: 4_000_000_000_000, usedBytes: 1_000_000_000_000, isBootVolume: true),
        VolumeInfo(name: "Untitled", mountPoint: "/Volumes/Untitled", totalBytes: 64_000_000_000, usedBytes: 6_400_000_000, isBootVolume: false),
    ])
    .padding()
    .frame(width: 400)
}
