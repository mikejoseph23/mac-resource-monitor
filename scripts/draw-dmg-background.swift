#!/usr/bin/env swift
// Generate the DMG background PNG: light surface with a green arrow that
// implicitly says "drag the app icon over to the Applications shortcut".
// Argument: output path.
import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: draw-dmg-background.swift <output.png>\n", stderr)
    exit(2)
}
let outputPath = CommandLine.arguments[1]

let width = 600
let height = 360

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0,
    bitsPerPixel: 32
) else {
    fputs("Failed to allocate bitmap\n", stderr)
    exit(1)
}

let ctx = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

let w = CGFloat(width)
let h = CGFloat(height)

// Subtle vertical gradient — looks crisper than flat white on retina.
let grad = NSGradient(colors: [
    NSColor(white: 0.985, alpha: 1),
    NSColor(white: 0.94, alpha: 1)
])!
grad.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

// Finder icon positions are measured from the TOP-LEFT of the icon area, but
// AppKit drawing y grows UPWARD. Icons will be centered at (icon_y from top)
// = 180, so in AppKit coords arrowY = h - 180 = 180.
let iconRowY = h - 180

// Arrow body — wide stroke between the two icons.
let arrowStart = NSPoint(x: 245, y: iconRowY)
let arrowEnd   = NSPoint(x: 355, y: iconRowY)

let arrow = NSBezierPath()
arrow.lineWidth = 8
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: arrowStart)
arrow.line(to: arrowEnd)

// Arrow head
let headLen: CGFloat = 18
let headSpread: CGFloat = 14
arrow.move(to: arrowEnd)
arrow.line(to: NSPoint(x: arrowEnd.x - headLen, y: arrowEnd.y + headSpread))
arrow.move(to: arrowEnd)
arrow.line(to: NSPoint(x: arrowEnd.x - headLen, y: arrowEnd.y - headSpread))

NSColor(calibratedRed: 0.20, green: 0.72, blue: 0.34, alpha: 1).setStroke()
arrow.stroke()

NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}
try data.write(to: URL(fileURLWithPath: outputPath))
