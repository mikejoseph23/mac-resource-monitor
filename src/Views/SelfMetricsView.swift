import SwiftUI

struct SelfMetricsView: View {
    let selfMetrics: AppSelfMetrics?

    private var cpuText: String {
        guard let m = selfMetrics else { return "--" }
        return String(format: "%.1f%%", m.cpuUsage)
    }

    private var memoryText: String {
        guard let m = selfMetrics else { return "--" }
        let mb = Double(m.memoryBytes) / (1024 * 1024)
        return String(format: "%.1f MB", mb)
    }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: "app.badge.checkmark")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("MacResourceMonitor")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 12) {
                Label {
                    Text(cpuText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                } icon: {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)

                Label {
                    Text(memoryText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                } icon: {
                    Image(systemName: "memorychip")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

#Preview {
    VStack(spacing: 0) {
        Spacer()
        SelfMetricsView(selfMetrics: AppSelfMetrics(cpuUsage: 1.3, memoryBytes: 48_000_000))
    }
    .frame(width: 600, height: 100)
}
