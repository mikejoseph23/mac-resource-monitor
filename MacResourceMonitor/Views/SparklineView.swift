import SwiftUI

struct SparklineView: View {
    let dataPoints: [(Date, Double)]
    let lineColor: Color
    let maxPoints: Int
    let fixedRange: (min: Double, max: Double)?

    init(dataPoints: [(Date, Double)], lineColor: Color = .blue, maxPoints: Int = 60, fixedRange: (min: Double, max: Double)? = nil) {
        self.dataPoints = dataPoints
        self.lineColor = lineColor
        self.maxPoints = maxPoints
        self.fixedRange = fixedRange
    }

    private var visiblePoints: [Double] {
        let values = dataPoints.suffix(maxPoints).map(\.1)
        return values
    }

    var body: some View {
        GeometryReader { geometry in
            let values = visiblePoints
            if values.count >= 2 {
                let minVal = fixedRange?.min ?? values.min() ?? 0
                let maxVal = fixedRange?.max ?? values.max() ?? 1
                let range = max(maxVal - minVal, 0.001)

                ZStack {
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
}

// MARK: - Shapes

private struct SparklineShape: Shape {
    let values: [Double]
    let minVal: Double
    let range: Double

    func path(in rect: CGRect) -> Path {
        guard values.count >= 2 else { return Path() }

        let stepX = rect.width / CGFloat(values.count - 1)
        let points: [CGPoint] = values.enumerated().map { index, value in
            let x = CGFloat(index) * stepX
            let normalised = CGFloat((value - minVal) / range)
            let y = rect.height - normalised * rect.height
            return CGPoint(x: x, y: y)
        }

        return Path { path in
            path.move(to: points[0])
            for i in 1..<points.count {
                let prev = points[i - 1]
                let curr = points[i]
                let midX = (prev.x + curr.x) / 2
                path.addCurve(
                    to: curr,
                    control1: CGPoint(x: midX, y: prev.y),
                    control2: CGPoint(x: midX, y: curr.y)
                )
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
        let points: [CGPoint] = values.enumerated().map { index, value in
            let x = CGFloat(index) * stepX
            let normalised = CGFloat((value - minVal) / range)
            let y = rect.height - normalised * rect.height
            return CGPoint(x: x, y: y)
        }

        return Path { path in
            path.move(to: CGPoint(x: points[0].x, y: rect.height))
            path.addLine(to: points[0])
            for i in 1..<points.count {
                let prev = points[i - 1]
                let curr = points[i]
                let midX = (prev.x + curr.x) / 2
                path.addCurve(
                    to: curr,
                    control1: CGPoint(x: midX, y: prev.y),
                    control2: CGPoint(x: midX, y: curr.y)
                )
            }
            path.addLine(to: CGPoint(x: points.last!.x, y: rect.height))
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
