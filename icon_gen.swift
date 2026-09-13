import AppKit

enum Variant { case light, dark }

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

// Apple's macOS 26+ icon silhouette, measured from system icons: superellipse n≈4.35, inset 9.77% per side.
func squircle(in r: NSRect, exponent n: CGFloat = 4.35) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let p = NSPoint(
            x: r.midX + r.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
            y: r.midY + r.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        if i == 0 { path.move(to: p) } else { path.line(to: p) }
    }
    path.close()
    return path
}

func drawIcon(side s: CGFloat, _ variant: Variant) {
    let dark = variant == .dark
    let inset = s * 0.0977
    let shape = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let S = shape.width
    let background = squircle(in: shape)

    let backgroundGradient = dark
        ? NSGradient(colorsAndLocations: (rgb(35, 35, 34), 0), (rgb(23, 23, 22), 0.55), (rgb(19, 19, 19), 1))!
        : NSGradient(colors: [rgb(63, 210, 116), rgb(9, 148, 78)])!
    backgroundGradient.draw(in: background, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    background.addClip()
    background.lineWidth = S * 0.010
    rgb(255, 255, 255, dark ? 0.10 : 0.22).setStroke()
    background.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // In dark mode the green moves from the background into the glyph, as in Apple's Messages icon.
    let glyphGradient = dark
        ? NSGradient(colors: [rgb(80, 235, 120), rgb(40, 180, 85)])!
        : NSGradient(colors: [rgb(255, 255, 255, 0.95), rgb(255, 255, 255, 0.95)])!

    let bodyW = S * 0.56, bodyH = S * 0.32
    let body = NSRect(
        x: shape.minX + (S - bodyW) / 2 - S * 0.03,
        y: shape.minY + (S - bodyH) / 2,
        width: bodyW, height: bodyH)

    func fillWithGlyphGradient(_ path: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        glyphGradient.draw(in: NSRect(x: shape.minX, y: body.minY - S * 0.0225, width: S, height: bodyH + S * 0.045), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }

    let bodyPath = NSBezierPath(roundedRect: body, xRadius: bodyH * 0.22, yRadius: bodyH * 0.22)
    fillWithGlyphGradient(NSBezierPath(cgPath: bodyPath.cgPath.copy(
        strokingWithWidth: S * 0.045, lineCap: .butt, lineJoin: .miter, miterLimit: 10)))

    let nubW = S * 0.035, nubH = bodyH * 0.4
    fillWithGlyphGradient(NSBezierPath(
        roundedRect: NSRect(x: body.maxX + S * 0.015, y: body.midY - nubH / 2, width: nubW, height: nubH),
        xRadius: nubW * 0.3, yRadius: nubW * 0.3))

    let boltH = bodyH * 0.78, boltW = boltH * 0.56
    let bolt = NSBezierPath()
    let points: [(CGFloat, CGFloat)] = [(0.18, 0.5), (-0.32, -0.05), (-0.02, -0.05), (-0.18, -0.5), (0.32, 0.08), (0.02, 0.08)]
    for (i, (x, y)) in points.enumerated() {
        let p = NSPoint(x: body.midX + x * boltW, y: body.midY + y * boltH)
        if i == 0 { bolt.move(to: p) } else { bolt.line(to: p) }
    }
    bolt.close()
    (dark ? rgb(94, 245, 133) : rgb(255, 255, 255)).setFill()
    bolt.fill()
}

let slots: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

for (variant, setName) in [(Variant.light, "AppIcon.iconset"), (.dark, "AppIcon-Dark.iconset")] {
    let setURL = outDir.appendingPathComponent(setName)
    try FileManager.default.createDirectory(at: setURL, withIntermediateDirectories: true)
    for (px, name) in slots {
        // An explicit pixel-sized bitmap, not NSImage.lockFocus(), which doubles pixels on Retina.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawIcon(side: CGFloat(px), variant)
        NSGraphicsContext.current = nil
        try rep.representation(using: .png, properties: [:])!.write(to: setURL.appendingPathComponent(name + ".png"))
    }
}
