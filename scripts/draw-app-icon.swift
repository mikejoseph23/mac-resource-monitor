#!/usr/bin/env swift
// Generate AppIcon.icns: a speedometer gauge on a dark squircle, drawn at
// every iconset size from vector code so small sizes stay crisp.
//
// The squircle is inset to 824/1024 of the canvas per Apple's icon grid —
// full-bleed artwork renders visibly larger than every other Dock icon.
//
// Argument: output .icns path.
import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: draw-app-icon.swift <output.icns>\n", stderr)
    exit(2)
}
let outputPath = CommandLine.arguments[1]

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    let a = a.usingColorSpace(.deviceRGB)!, b = b.usingColorSpace(.deviceRGB)!
    return NSColor(
        red: lerp(a.redComponent, b.redComponent, t),
        green: lerp(a.greenComponent, b.greenComponent, t),
        blue: lerp(a.blueComponent, b.blueComponent, t),
        alpha: 1
    )
}

// Severity ramp along the gauge, matching the app's green→yellow→orange→red.
let ramp = [color(0x30D158), color(0x30D158), color(0xAFD34E), color(0xFFD60A), color(0xFF9F0A)]
func rampColor(_ t: CGFloat) -> NSColor {
    let scaled = max(0, min(1, t)) * CGFloat(ramp.count - 1)
    let i = min(ramp.count - 2, Int(scaled))
    return mix(ramp[i], ramp[i + 1], scaled - CGFloat(i))
}

/// Draw the icon into the current graphics context at `px` square.
func drawIcon(px: CGFloat) {
    let u = px / 1024                       // proportional unit
    let small = px <= 32                    // legibility tweaks for tiny sizes

    // Apple icon grid: artwork squircle is 824pt of a 1024pt canvas. At tiny
    // sizes shrink the margin a touch so the mark doesn't vanish.
    let squircleSize = (small ? 880 : 824) * u
    let margin = (px - squircleSize) / 2
    let rect = NSRect(x: margin, y: margin, width: squircleSize, height: squircleSize)
    let cornerRadius = squircleSize * 0.2237

    // Baked drop shadow, like Apple's template icons. Skip when tiny.
    if !small {
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
        shadow.shadowBlurRadius = 22 * u
        shadow.set()
        color(0x171B21).setFill()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // Background: dark slate vertical gradient.
    let clip = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSGraphicsContext.current?.saveGraphicsState()
    clip.addClip()
    NSGradient(colors: [color(0x2E3540), color(0x171B21)])!.draw(in: rect, angle: -90)

    // Faint glow behind the gauge so the dark field isn't flat.
    let center = NSPoint(x: rect.midX, y: rect.midY - 20 * u)
    NSGradient(colors: [color(0x30D158, 0.16), color(0x30D158, 0)])!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: 430 * u)

    // Gauge geometry: 240° sweep, symmetric, opening at the bottom.
    // AppKit angles: 0° = right, counterclockwise positive.
    let startAngle: CGFloat = 210          // lower left
    let sweep: CGFloat = 240               // ends lower right (-30°)
    let radius = 262 * u
    let stroke = (small ? 128 : 96) * u
    let progress: CGFloat = 0.70           // needle position along the sweep

    func point(onArc t: CGFloat, radius r: CGFloat) -> NSPoint {
        let deg = startAngle - sweep * t   // clockwise from start
        let rad = deg * .pi / 180
        return NSPoint(x: center.x + r * cos(rad), y: center.y + r * sin(rad))
    }

    // Track: the dim remainder of the dial.
    let track = NSBezierPath()
    track.lineWidth = stroke
    track.lineCapStyle = .round
    track.appendArc(withCenter: center, radius: radius,
                    startAngle: startAngle, endAngle: startAngle - sweep, clockwise: true)
    color(0xFFFFFF, 0.10).setStroke()
    track.stroke()

    // Progress arc: many short overlapping segments fake a conic gradient.
    let segments = 96
    for i in 0..<Int(CGFloat(segments) * progress) {
        let t0 = CGFloat(i) / CGFloat(segments)
        let t1 = CGFloat(i + 1) / CGFloat(segments) + 0.004
        let seg = NSBezierPath()
        seg.lineWidth = stroke
        seg.lineCapStyle = i == 0 ? .round : .butt
        seg.appendArc(withCenter: center, radius: radius,
                      startAngle: startAngle - sweep * t0,
                      endAngle: startAngle - sweep * min(t1, progress),
                      clockwise: true)
        rampColor(t0 / progress * 0.85).setStroke()
        seg.stroke()
    }
    // Round cap on the leading end.
    let capCenter = point(onArc: progress, radius: radius)
    rampColor(0.85).setFill()
    NSBezierPath(ovalIn: NSRect(x: capCenter.x - stroke / 2, y: capCenter.y - stroke / 2,
                                width: stroke, height: stroke)).fill()

    // Needle pointing at the progress cap, plus center hub.
    if !small {
        let needleShadow = NSShadow()
        needleShadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        needleShadow.shadowOffset = NSSize(width: 0, height: -6 * u)
        needleShadow.shadowBlurRadius = 12 * u

        NSGraphicsContext.current?.saveGraphicsState()
        needleShadow.set()
        let needle = NSBezierPath()
        needle.lineWidth = 30 * u
        needle.lineCapStyle = .round
        needle.move(to: center)
        needle.line(to: point(onArc: progress, radius: radius - stroke / 2 - 26 * u))
        NSColor.white.setStroke()
        needle.stroke()

        let hubRadius = 52 * u
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - hubRadius, y: center.y - hubRadius,
                                    width: hubRadius * 2, height: hubRadius * 2)).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        color(0x171B21).setFill()
        let pin = 18 * u
        NSBezierPath(ovalIn: NSRect(x: center.x - pin, y: center.y - pin,
                                    width: pin * 2, height: pin * 2)).fill()
    }

    NSGraphicsContext.current?.restoreGraphicsState()
}

func renderPNG(px: Int, to url: URL) {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 32
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    drawIcon(px: CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    try! bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

for size in [16, 32, 128, 256, 512] {
    renderPNG(px: size, to: tmp.appendingPathComponent("icon_\(size)x\(size).png"))
    renderPNG(px: size * 2, to: tmp.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", tmp.path, "-o", outputPath]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: tmp)
guard iconutil.terminationStatus == 0 else {
    fputs("iconutil failed\n", stderr)
    exit(1)
}
print("Wrote \(outputPath)")
