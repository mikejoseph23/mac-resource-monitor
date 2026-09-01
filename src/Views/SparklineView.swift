import SwiftUI

struct SparklineView: View {
    let dataPoints: [(Date, Double)]
    let lineColor: Color
    let maxPoints: Int
    let fixedRange: (min: Double, max: Double)?
    let timeRangeSeconds: TimeInterval?
    var valueFormatter: ((Double) -> String)?
    /// Draws min/max scale labels in a reserved left gutter. Auto-ranged
    /// sparklines otherwise render a flat-low series identically to a flat-high
    /// one, so the labels are what tell you *which* level the line is sitting at.
    var showScaleLabels: Bool

    /// Width of the axis gutter the plot is inset by so the scale labels never
    /// sit on top of the line.
    private let gutterWidth: CGFloat = 36

    @State private var hoverIndex: Int?

    init(
        dataPoints: [(Date, Double)],
        lineColor: Color = .blue,
        maxPoints: Int = 1800,
        fixedRange: (min: Double, max: Double)? = nil,
        timeRangeSeconds: TimeInterval? = nil,
        valueFormatter: ((Double) -> String)? = nil,
        showScaleLabels: Bool = true
    ) {
        self.dataPoints = dataPoints
        self.lineColor = lineColor
        self.maxPoints = maxPoints
        self.fixedRange = fixedRange
        self.timeRangeSeconds = timeRangeSeconds
        self.valueFormatter = valueFormatter
        self.showScaleLabels = showScaleLabels
    }

    private var visibleData: [(Date, Double)] {
        Array(dataPoints.suffix(maxPoints))
    }

    private var visibleValues: [Double] {
        visibleData.map(\.1)
    }

    var body: some View {
        GeometryReader { geometry in
            let data = visibleData
            let values = data.map(\.1)
            if values.count >= 2 {
                let minVal = fixedRange?.min ?? values.min() ?? 0
                let maxVal = fixedRange?.max ?? values.max() ?? 1
                let range = max(maxVal - minVal, 0.001)

                // Position points proportionally within the time window, anchored
                // to the right edge. Newest sample sits at the right; older samples
                // scroll left. Before enough history accumulates, the left side
                // stays empty (Activity Monitor / Task Manager behavior).
                let now = Date()
                let dataSpan = now.timeIntervalSince(data.first!.0)
                let effectiveDuration = timeRangeSeconds ?? max(dataSpan, 1)
                let effectiveStart = now.addingTimeInterval(-effectiveDuration)
                let gutter: CGFloat = showScaleLabels ? min(gutterWidth, geometry.size.width * 0.25) : 0
                let plotWidth = max(geometry.size.width - gutter, 1)
                let xPositions: [CGFloat] = data.map { point in
                    let elapsed = point.0.timeIntervalSince(effectiveStart)
                    return gutter + plotWidth * CGFloat(elapsed / effectiveDuration)
                }

                ZStack(alignment: .topLeading) {
                    // Horizontal grid lines (4 lines at 25%, 50%, 75%, 100%)
                    ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { fraction in
                        let y = geometry.size.height - CGFloat(fraction) * geometry.size.height
                        Path { path in
                            path.move(to: CGPoint(x: gutter, y: y))
                            path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                        }
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                    }

                    // Fill gradient beneath the line
                    SparklineFillShape(values: values, xPositions: xPositions, minVal: minVal, range: range)
                        .fill(
                            LinearGradient(
                                colors: [lineColor.opacity(0.25), lineColor.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Line stroke
                    SparklineShape(values: values, xPositions: xPositions, minVal: minVal, range: range)
                        .stroke(lineColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                    // Hover indicator
                    if let idx = hoverIndex, idx < values.count {
                        let x = xPositions[idx]
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

                    // Min/max scale labels (top = ceiling, bottom = floor) live
                    // in a reserved gutter to the left of the plot, so they can
                    // never collide with the line. Hidden while hovering so the
                    // tooltip owns the readout.
                    if showScaleLabels && gutter > 0 && hoverIndex == nil {
                        VStack(alignment: .trailing, spacing: 0) {
                            scaleLabel(maxVal)
                            Spacer(minLength: 0)
                            if maxVal - minVal > 0.001 {
                                scaleLabel(minVal)
                            }
                        }
                        .frame(width: gutter, height: geometry.size.height, alignment: .topTrailing)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        // Find the closest data point to the hover x position
                        let hoverX = location.x
                        var closestIdx = 0
                        var closestDist = CGFloat.greatestFiniteMagnitude
                        for (i, px) in xPositions.enumerated() {
                            let dist = abs(px - hoverX)
                            if dist < closestDist {
                                closestDist = dist
                                closestIdx = i
                            }
                        }
                        hoverIndex = closestIdx
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

    private func scaleLabel(_ value: Double) -> some View {
        let text = valueFormatter?(value) ?? defaultFormat(value)
        return Text(text)
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.trailing, 4)
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
    let xPositions: [CGFloat]
    let minVal: Double
    let range: Double

    func path(in rect: CGRect) -> Path {
        guard values.count >= 2 else { return Path() }

        return Path { path in
            for (index, value) in values.enumerated() {
                let x = xPositions[index]
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
    let xPositions: [CGFloat]
    let minVal: Double
    let range: Double

    func path(in rect: CGRect) -> Path {
        guard values.count >= 2 else { return Path() }

        return Path { path in
            // Start at bottom beneath first data point
            path.move(to: CGPoint(x: xPositions[0], y: rect.height))

            for (index, value) in values.enumerated() {
                let x = xPositions[index]
                let normalised = CGFloat((value - minVal) / range)
                let y = rect.height - normalised * rect.height
                path.addLine(to: CGPoint(x: x, y: y))
            }

            // Close along the bottom
            path.addLine(to: CGPoint(x: xPositions[values.count - 1], y: rect.height))
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
