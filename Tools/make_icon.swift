import AppKit

// Renders the Murmur app icon: a voice waveform that resolves into a text caret,
// on a deep indigo squircle. Usage: swift make_icon.swift <out.iconset>

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle with the standard macOS icon margin.
    let inset = s * 0.0977
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(red: 0.13, green: 0.12, blue: 0.30, alpha: 1).setFill()
    path.fill()
    ctx.restoreGState()

    ctx.saveGState()
    path.addClip()
    let gradient = NSGradient(colors: [NSColor(red: 0.36, green: 0.30, blue: 0.80, alpha: 1),
                                       NSColor(red: 0.12, green: 0.10, blue: 0.29, alpha: 1)])!
    gradient.draw(in: body, angle: -65)
    // Soft top highlight.
    let sheen = NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
    sheen.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    ctx.restoreGState()

    // Waveform bars + caret.
    let heights: [CGFloat] = [0.34, 0.62, 1.0, 0.62]
    let barW = body.width * 0.082, gap = body.width * 0.062
    let caretGap = body.width * 0.115, caretW = barW * 0.82
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap + caretGap + caretW
    var x = body.midX - total / 2
    let maxH = body.height * 0.5
    NSColor(red: 0.96, green: 0.94, blue: 1.0, alpha: 1).setFill()
    for h in heights {
        let bh = maxH * h * 0.8
        NSBezierPath(roundedRect: NSRect(x: x, y: body.midY - bh / 2, width: barW, height: bh),
                     xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    x += caretGap - gap
    NSColor(red: 1.0, green: 0.48, blue: 0.35, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: body.midY - maxH / 2, width: caretW, height: maxH),
                 xRadius: caretW / 2, yRadius: caretW / 2).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
