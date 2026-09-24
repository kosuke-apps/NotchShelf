import AppKit

// Renders AppIcon.icns. The mark is the notch itself with items coming back out of it.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let unit = size / 1024
    let art = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let body = NSBezierPath(roundedRect: art, xRadius: 185 * unit, yRadius: 185 * unit)

    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.27, alpha: 1),
                        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1)])?
        .draw(in: body, angle: -90)

    // The notch: a black tab hanging from the top edge of the art.
    let notchWidth = art.width * 0.46
    let notchHeight = art.height * 0.20
    let notch = NSRect(x: art.midX - notchWidth / 2, y: art.maxY - notchHeight,
                       width: notchWidth, height: notchHeight)
    // Clipped to the body so it reads as a notch cut out of the top edge, not a tab on top.
    NSGraphicsContext.saveGraphicsState()
    body.setClip()
    let notchPath = NSBezierPath(roundedRect: notch.insetBy(dx: 0, dy: -80 * unit),
                                 xRadius: 60 * unit, yRadius: 60 * unit)
    NSColor.black.setFill()
    notchPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Three items emerging below it, brightest in the middle.
    let dot = 108 * unit
    let gap = 46 * unit
    let totalWidth = dot * 3 + gap * 2
    let y = art.minY + art.height * 0.24
    let alphas: [CGFloat] = [0.55, 1.0, 0.55]
    for index in 0..<3 {
        let rect = NSRect(x: art.midX - totalWidth / 2 + CGFloat(index) * (dot + gap),
                          y: y, width: dot, height: dot)
        NSColor.white.withAlphaComponent(alphas[index]).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 30 * unit, yRadius: 30 * unit).fill()
    }

    // A chevron pointing down out of the notch: the gesture the app is about.
    let chevron = NSBezierPath()
    let cx = art.midX, cy = art.maxY - notchHeight - 90 * unit
    let arm = 78 * unit
    chevron.move(to: NSPoint(x: cx - arm, y: cy + arm * 0.55))
    chevron.line(to: NSPoint(x: cx, y: cy - arm * 0.55))
    chevron.line(to: NSPoint(x: cx + arm, y: cy + arm * 0.55))
    chevron.lineWidth = 40 * unit
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.92).setStroke()
    chevron.stroke()

    return image
}

func png(_ image: NSImage, size: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(size), pixelsHigh: Int(size),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let output = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for (name, size) in [("16x16", 16.0), ("16x16@2x", 32.0), ("32x32", 32.0), ("32x32@2x", 64.0),
                     ("128x128", 128.0), ("128x128@2x", 256.0), ("256x256", 256.0),
                     ("256x256@2x", 512.0), ("512x512", 512.0), ("512x512@2x", 1024.0)] {
    let image = drawIcon(size: size)
    if let data = png(image, size: size) {
        try? data.write(to: URL(fileURLWithPath: "\(output)/icon_\(name).png"))
    }
}
print("wrote iconset to \(output)")
