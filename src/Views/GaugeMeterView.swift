import SwiftUI

struct GaugeMeterView: View {
    let title: String
    let icon: String
    let percent: Double
    let subtitle: String
    let severity: MetricSeverity

    private let lineWidth: CGFloat = 10
    private let startAngle: Angle = .degrees(135)
    private let endAngle: Angle = .degrees(405)

    private var progressAngle: Angle {
        let clampedPercent = min(max(percent, 0), 100) / 100.0
        let sweep = endAngle.degrees - startAngle.degrees
        return .degrees(startAngle.degrees + sweep * clampedPercent)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Track arc
                ArcShape(startAngle: startAngle, endAngle: endAngle)
                    .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

                // Value arc
                ArcShape(startAngle: startAngle, endAngle: progressAngle)
                    .stroke(
                        AngularGradient(
                            colors: [severity.color.opacity(0.6), severity.color],
                            center: .center,
                            startAngle: startAngle,
                            endAngle: progressAngle
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )

                // Center content
                VStack(spacing: 2) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(severity.color)

                    Text(String(format: "%.0f%%", percent))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }
            .frame(width: 100, height: 100)

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(severity.color.opacity(0.15), lineWidth: 1)
                )
        }
    }
}

// MARK: - Arc Shape

private struct ArcShape: Shape {
    let startAngle: Angle
    let endAngle: Angle

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addArc(
                center: CGPoint(x: rect.midX, y: rect.midY),
                radius: min(rect.width, rect.height) / 2,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: false
            )
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        GaugeMeterView(
            title: "CPU",
            icon: "cpu",
            percent: 42,
            subtitle: "8 cores",
            severity: .normal
        )
        GaugeMeterView(
            title: "Memory",
            icon: "memorychip",
            percent: 78,
            subtitle: "124.8 / 192 GB",
            severity: .warning
        )
        GaugeMeterView(
            title: "Disk",
            icon: "internaldrive",
            percent: 55,
            subtitle: "1.1 / 2.0 TB used",
            severity: .normal
        )
    }
    .padding()
    .frame(width: 500)
}
