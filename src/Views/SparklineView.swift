import SwiftUI

struct SparklineView: View {
    let dataPoints: [(Date, Double)]
    let lineColor: Color
    let maxPoints: Int
    let fixedRange: (min: Double, max: Double)?
    var valueFormatter: ((Double) -> String)?

    @State private var hoverIndex: Int?

    init(
        dataPoints: [(Date, Double)],
        lineColor: Color = .blue,
        maxPoints: Int = 1800,
        fixedRange: (min: Double, max: Double)? = nil,
        valueFormatter: ((Double) -> String)? = nil
    ) {
        self.dataPoints = dataPoints
        self.lineColor = lineColor
        self.maxPoints = maxPoints
        self.fixedRange = fixedRange
        self.valueFormatter = valueFormatter
    }

    private var visibleData: [(Date, Double)] {
        Array(dataPoints.suffix(maxPoints))
    }

    private var visibleValues: [Double] {
        visibleData.map(\.1)
    }

    var body: some View {
        GeometryReader { geometry in
            let values = visibleValues
            if values.count >= 2 {
                let minVal = fixedRange?.min ?? values.min() ?? 0
                let maxVal = fixedRange?.max ?? values.max() ?? 1
                let range = max(maxVal - minVal, 0.001)
                let stepX = geometry.size.width / CGFloat(values.count - 1)

                ZStack(alignment: .topLeading) {
                    // Fill gradient beneath the line
                    SparklineFillShape(values: values, minVal: minVal, range: range)
                        .fill(
                            LinearGradient(
                                colors: [lineColor.opacity(0.25), lineColor.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Line stroke
                    SparklineShape(values: values, minVal: minVal, range: range)
                        .stroke(lineColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                    // Hover indicator
                    if let idx = hoverIndex, idx < values.count {
                        let x = CGFloat(idx) * stepX
                        let normalised = CGFloat((values[idx] - minVal) / range)
                        let y = geometry.size.height - normalised * geometry.size.height

                        // Vertical guide line
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                        }
                        .stroke(lineColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))

                        // Dot on the line
                        Circle()
                            .fill(lineColor)
                            .frame(width: 6, height: 6)
                            .position(x: x, y: y)

                        // Tooltip
                        sparklineTooltip(index: idx, x: x, containerWidth: geometry.size.width)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let idx = Int((location.x / stepX).rounded())
                        hoverIndex = max(0, min(idx, values.count - 1))
                    case .ended:
                        hoverIndex = nil
                    @unknown default:
                        hoverIndex = nil
                    }
                }
            } else {
                // Not enough data — show a flat baseline
                Path { path in
                    let y = geometry.size.height * 0.5
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
                .stroke(lineColor.opacity(0.3), lineWidth: 1)
            }
        }
    }

    private func sparklineTooltip(index: Int, x: CGFloat, containerWidth: CGFloat) -> some View {
        let data = visibleData
        let point = data[index]
        let formattedValue = valueFormatter?(point.1) ?? defaultFormat(point.1)
        let formattedTime = timeFormatter.string(from: point.0)

        // Anchor tooltip to the left or right of the cursor to stay in bounds
        let anchorRight = x < containerWidth / 2

        return VStack(alignment: .leading, spacing: 2) {
            Text(formattedValue)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(formattedTime)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.ultraThickMaterial)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .fixedSize()
        .position(x: anchorRight ? x + 45 : x - 45, y: 0)
    }

    private func defaultFormat(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1f MB/s", value / (1024 * 1024))
        }
        if value >= 1_000 {
            return String(format: "%.0f KB/s", value / 1024)
        }
        if fixedRange != nil {
            return String(format: "%.1f%%", value)
        }
        return String(format: "%.1f", value)
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss a"
        return f
    }
}

// MARK: - Shapes

private struct SparklineShape: Shape {
    let values: [Double]
    let minVal: Double
    let range: Double

    func path(in rect: CGRect) -> Path {
        guard values.count >= 2 else { return Path() }

        let stepX = rect.width / CGFloat(values.count - 1)

        return Path { path in
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * stepX
                let normalised = CGFloat((value - minVal) / range)
                let y = rect.height - normalised * rect.height
                let point = CGPoint(x: x, y: y)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
        }
    }
}

private struct SparklineFillShape: Shape {
    let values: [Double]
    let minVal: Double
    let range: Double

    func path(in rect: CGRect) -> Path {
        guard values.count >= 2 else { return Path() }

        let stepX = rect.width / CGFloat(values.count - 1)

        return Path { path in
            // Start at bottom-left
            path.move(to: CGPoint(x: 0, y: rect.height))

            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * stepX
                let normalised = CGFloat((value - minVal) / range)
                let y = rect.height - normalised * rect.height
                path.addLine(to: CGPoint(x: x, y: y))
            }

            // Close along the bottom
            path.addLine(to: CGPoint(x: CGFloat(values.count - 1) * stepX, y: rect.height))
            path.closeSubpath()
        }
    }
}

#Preview {
    let sampleData: [(Date, Double)] = (0..<30).map { i in
        let date = Date().addingTimeInterval(Double(-30 + i) * 2)
        let value = 30.0 + 40.0 * sin(Double(i) * 0.3) + Double.random(in: -5...5)
        return (date, value)
    }

    SparklineView(dataPoints: sampleData, lineColor: .green)
        .frame(width: 200, height: 50)
        .padding()
}
