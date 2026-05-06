import SwiftUI

struct MetricCardView: View {
    let title: String
    let icon: String
    let value: String
    let subtitle: String
    let severity: MetricSeverity
    let sparklineData: [(Date, Double)]
    var accentColor: Color = .blue
    var sparklineFixedRange: (min: Double, max: Double)? = nil
    var sparklineTimeRangeSeconds: TimeInterval? = nil
    var sparklineValueFormatter: ((Double) -> String)? = nil
    var details: [(label: String, value: String, color: Color?)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header row: icon + title + severity dot
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accentColor)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Circle()
                    .fill(severity.color)
                    .frame(width: 6, height: 6)
            }

            // Value + subtitle on one row
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            // Sparkline
            SparklineView(dataPoints: sparklineData, lineColor: severity.color, fixedRange: sparklineFixedRange, timeRangeSeconds: sparklineTimeRangeSeconds, valueFormatter: sparklineValueFormatter)
                .frame(height: 28)
                .padding(.top, 2)

            // Detail breakdown rows
            if !details.isEmpty {
                Divider()
                    .opacity(0.3)
                    .padding(.top, 2)

                VStack(spacing: 2) {
                    ForEach(details, id: \.label) { detail in
                        detailRow(detail)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(severity.color.opacity(0.15), lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private func detailRow(_ detail: (label: String, value: String, color: Color?)) -> some View {
        let labelColor: Color = detail.color ?? Color.secondary.opacity(0.5)
        let valueColor: Color = detail.color ?? Color.secondary
        HStack {
            Text(detail.label)
                .foregroundColor(labelColor)
            Spacer()
            Text(detail.value)
                .foregroundColor(valueColor)
        }
        .font(.system(size: 10, design: .monospaced))
    }
}

// MARK: - Severity

enum MetricSeverity {
    case normal
    case warning
    case critical

    var color: Color {
        switch self {
        case .normal:   return .green
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    /// Create severity from a 0-100 percentage value.
    static func from(percent: Double, warningAt: Double = 70, criticalAt: Double = 90) -> MetricSeverity {
        if percent >= criticalAt { return .critical }
        if percent >= warningAt  { return .warning }
        return .normal
    }
}

#Preview {
    let sampleData: [(Date, Double)] = (0..<30).map { i in
        let date = Date().addingTimeInterval(Double(-30 + i) * 2)
        let value = 30.0 + 25.0 * sin(Double(i) * 0.3) + Double.random(in: -3...3)
        return (date, value)
    }

    HStack(spacing: 16) {
        MetricCardView(
            title: "CPU",
            icon: "cpu",
            value: "42%",
            subtitle: "8 cores",
            severity: .normal,
            sparklineData: sampleData
        )
        MetricCardView(
            title: "Memory",
            icon: "memorychip",
            value: "78%",
            subtitle: "12.5 / 16 GB",
            severity: .warning,
            sparklineData: sampleData
        )
        MetricCardView(
            title: "Thermal",
            icon: "thermometer.medium",
            value: "Critical",
            subtitle: "Throttled",
            severity: .critical,
            sparklineData: sampleData
        )
    }
    .padding()
    .frame(width: 700)
}
