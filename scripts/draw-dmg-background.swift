#!/usr/bin/env swift
// Generate the DMG install-window background art, modelled on the LymeScribe
// installer look: a near-white window with a green "drag →" arrow between the
// app icon (left) and the /Applications alias (right), the instruction text
// below, and a faint brand motif echoing the app icon's gauge ramp.
//
// Draws guidance ONLY — the icon slots are left empty; Finder paints the real
// app icon and /Applications alias on top at the coordinates make-dmg.sh
// positions them (150,185 and 450,185 in a 600x400 pt window).
//
// Emits two files so make-dmg.sh can fuse them into a HiDPI TIFF
// (tiffutil -cathidpicheck): background.png (600x400, 1x) and
// background@2x.png (1200x800, retina). Argument: output directory.
import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("usage: draw-dmg-background.swift <output-dir>\n", stderr)
    exit(2)
}
let outDir = CommandLine.arguments[1]

// Logical window (points). Must agree with make-dmg.sh's window + icon positions.
let W = 600, H = 400
let appCenter  = NSPoint(x: 150, y: 185)   // left slot  (Finder paints app icon)
let appsCenter = NSPoint(x: 450, y: 185)   // right slot (Finder paints /Applications)

// Palette keyed to the app icon (dark gauge face, green→amber ramp needle).
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r/255, green: g/255, blue: b/255, alpha: a)
}
let bgTop    = rgb(248, 250, 249)     // near-white, faint cool tint
let bgBottom = rgb(230, 236, 233)
let arrowCol = rgb(48, 209, 88)       // #30D158 — the icon's ramp green
let textCol  = rgb(60, 92, 74)        // deep green-grey, legible on near-white
let motifCol = rgb(48, 209, 88)       // faint ramp motif (drawn low-alpha)

func render(scale: Int) -> NSBitmapImageRep {
    let pw = W * scale, ph = H * scale
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 32)!
    let ctx = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    let s = CGFloat(scale)
    _ = s
    let wf = CGFloat(W), hf = CGFloat(H)

    // Vertical gradient background.
    NSGradient(colors: [bgTop, bgBottom])!.draw(in: NSRect(x: 0, y: 0, width: wf, height: hf), angle: -90)

    // AppKit y grows upward; Finder positions are from the top. Convert.
    func flip(_ y: CGFloat) -> CGFloat { hf - y }

    // Faint gauge-ramp motif along the bottom: a row of rounded bars whose
    // heights rise then fall, echoing the app icon's needle ramp.
    let baseY = flip(360)
    let heights: [CGFloat] = [10, 18, 28, 40, 54, 40, 28, 18, 10]
    let barW: CGFloat = 9, gap: CGFloat = 22
    let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = (wf - totalW) / 2
    for hgt in heights {
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: baseY, width: barW, height: hgt),
                               xRadius: barW/2, yRadius: barW/2)
        motifCol.withAlphaComponent(0.14).setFill()
        bar.fill()
        x += barW + gap
    }

    // Arrow: app slot → Applications slot.
    let ay = flip(appCenter.y)
    let x0 = appCenter.x + 74          // just right of the app icon
    let x1 = appsCenter.x - 74         // just left of the alias
    let shaft = NSBezierPath()
    shaft.lineWidth = 9
    shaft.lineCapStyle = .round
    shaft.move(to: NSPoint(x: x0, y: ay))
    shaft.line(to: NSPoint(x: x1 - 16, y: ay))
    arrowCol.setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    let headLen: CGFloat = 24, spread: CGFloat = 20
    head.move(to: NSPoint(x: x1, y: ay))
    head.line(to: NSPoint(x: x1 - headLen, y: ay + spread))
    head.line(to: NSPoint(x: x1 - headLen, y: ay - spread))
    head.close()
    arrowCol.setFill()
    head.fill()

    // Instruction text, centered, below the icon row (clear of Finder's labels).
    let instr = "Drag to Applications to install"
    let font = NSFont.systemFont(ofSize: 17, weight: .medium)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textCol]
    let size = (instr as NSString).size(withAttributes: attrs)
    (instr as NSString).draw(at: NSPoint(x: (wf - size.width)/2, y: flip(300) - size.height/2),
                             withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func write(_ bitmap: NSBitmapImageRep, to path: String) {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Failed to encode PNG: \(path)\n", stderr); exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: path))
    fputs("wrote \(path)\n", stderr)
}

write(render(scale: 1), to: "\(outDir)/background.png")
write(render(scale: 2), to: "\(outDir)/background@2x.png")
