import AppKit

// Renders the Murmur promo animation as raw BGRA frames on stdout (pipe into ffmpeg).
// Usage: make_promo <width> <height> <icon.png> [teaser|full]
// "full" inserts a feature tour between the demo and the proof scenes.
// All layout is in a 1080-unit design space centred on the canvas, y up.

let W = Int(CommandLine.arguments[1])!
let H = Int(CommandLine.arguments[2])!
let iconPath = CommandLine.arguments[3]
let full = CommandLine.arguments.count > 4 && CommandLine.arguments[4] == "full"
let FPS = 30.0
let FEAT0 = 10.6                          // feature tour starts as the demo fades out
let FEAT_LEN = 27.4
let shift = full ? FEAT0 + FEAT_LEN - 10.45 : 0   // proof + CTA move back by this much
let DURATION = 20.0 + shift

let u = Double(min(W, H)) / 1080          // size scale
let ky = H > W ? 1.3 : 1.0                // vertical formats spread the stack out

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let icon = NSImage(contentsOfFile: iconPath)

// MARK: helpers

func hex(_ v: UInt32, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
            blue: CGFloat(v & 255) / 255, alpha: CGFloat(a))
}
let ink = hex(0xFFFFFF), muted = hex(0xA9A7D6), violet = hex(0x8B7CFF), cyan = hex(0x52E0FF)
let red = hex(0xFF453A), card = hex(0x1F1D4A), dim = hex(0x6F6D9E)

func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
func prog(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
func easeInOut(_ x: Double) -> Double { let c = clamp(x); return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2 }
func easeBack(_ x: Double) -> Double { let c1 = 1.70158, c3 = c1 + 1, c = clamp(x); return 1 + c3 * pow(c - 1, 3) + c1 * pow(c - 1, 2) }
/// 1 while t is inside [a, b], fading over `f` seconds at both ends.
func win(_ t: Double, _ a: Double, _ b: Double, _ f: Double = 0.35) -> Double {
    min(easeOut(prog(t, a, a + f)), 1 - easeInOut(prog(t, b - f, b)))
}

func X(_ x: Double) -> CGFloat { CGFloat(W) / 2 + CGFloat(x * u) }
func Y(_ y: Double) -> CGFloat { CGFloat(H) / 2 + CGFloat(y * u * ky) }

func font(_ size: Double, _ weight: NSFont.Weight = .bold) -> NSFont {
    let base = NSFont.systemFont(ofSize: CGFloat(size * u), weight: weight)
    if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: CGFloat(size * u)) { return f }
    return base
}
func attr(_ s: String, _ f: NSFont, _ c: NSColor) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c])
}

func drawText(_ a: NSAttributedString, cx: Double, cy: Double, alpha: Double = 1, scale: Double = 1, dy: Double = 0, dx: Double = 0) {
    guard alpha > 0.002 else { return }
    let sz = a.size()
    ctx.saveGState()
    ctx.setAlpha(CGFloat(alpha))
    ctx.translateBy(x: X(cx) + CGFloat(dx * u), y: Y(cy) + CGFloat(dy * u))
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    a.draw(at: NSPoint(x: -sz.width / 2, y: -sz.height / 2))
    ctx.restoreGState()
}

func rrect(cx: Double, cy: Double, w: Double, h: Double, r: Double, fill: NSColor? = nil, stroke: NSColor? = nil,
           lw: Double = 2, alpha: Double = 1, scale: Double = 1, dx: Double = 0, dy: Double = 0, shadow: Bool = false) {
    guard alpha > 0.002 else { return }
    ctx.saveGState()
    ctx.setAlpha(CGFloat(alpha))
    ctx.translateBy(x: X(cx) + CGFloat(dx * u), y: Y(cy) + CGFloat(dy * u))
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    let rect = NSRect(x: -w * u / 2, y: -h * u / 2, width: w * u, height: h * u)
    let path = NSBezierPath(roundedRect: rect, xRadius: r * u, yRadius: r * u)
    if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -14 * u), blur: 40 * u, color: NSColor.black.withAlphaComponent(0.45).cgColor) }
    if let fill { fill.setFill(); path.fill() }
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    if let stroke { stroke.setStroke(); path.lineWidth = CGFloat(lw * u); path.stroke() }
    ctx.restoreGState()
}

func glow(cx: Double, cy: Double, radius: Double, color: NSColor, alpha: Double) {
    let g = CGGradient(colorsSpace: cs, colors: [color.withAlphaComponent(CGFloat(alpha)).cgColor,
                                                 color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy), endRadius: CGFloat(radius), options: [])
}

func symbol(_ name: String, size: Double, cx: Double, cy: Double, alpha: Double = 1, dx: Double = 0) {
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(size * u), weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else {
        FileHandle.standardError.write(Data("missing symbol \(name)\n".utf8)); return
    }
    let s = img.size
    // NSImage.draw ignores the context alpha, so fade through `fraction`
    img.draw(in: NSRect(x: X(cx) + CGFloat(dx * u) - s.width / 2, y: Y(cy) - s.height / 2, width: s.width, height: s.height),
             from: .zero, operation: .sourceOver, fraction: CGFloat(clamp(alpha)))
}

// MARK: background

func background(_ t: Double) {
    let g = CGGradient(colorsSpace: cs, colors: [hex(0x17143F).cgColor, hex(0x0A0920).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(H)), end: CGPoint(x: 0, y: 0), options: [])
    let big = Double(max(W, H))
    glow(cx: Double(W) * (0.2 + 0.08 * sin(t * 0.35)), cy: Double(H) * (0.82 + 0.04 * cos(t * 0.3)),
         radius: big * 0.6, color: violet, alpha: 0.30)
    glow(cx: Double(W) * (0.82 + 0.06 * cos(t * 0.3)), cy: Double(H) * (0.18 + 0.04 * sin(t * 0.4)),
         radius: big * 0.55, color: cyan, alpha: 0.16)
    // faint waveform lines
    for k in 0..<3 {
        let path = CGMutablePath()
        let base = Double(H) * (0.5 + 0.18 * Double(k - 1))
        var x = 0.0
        while x <= Double(W) {
            let env = 0.5 + 0.5 * sin(x / Double(W) * .pi)
            let y = base + env * 38 * u * sin(x * 0.012 + t * (0.8 + 0.2 * Double(k)) + Double(k) * 1.7)
            if x == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            x += 8
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.05).cgColor)
        ctx.setLineWidth(CGFloat(2 * u))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

// MARK: scene 1 - hook

func lineOfWords(_ words: [(String, NSColor)], size: Double, cy: Double, start: Double, stagger: Double, t: Double, fade: Double) {
    let maxW = 940.0 * u
    var f = font(size, .heavy)
    func total(_ f: NSFont) -> CGFloat {
        words.map { attr($0.0, f, ink).size().width }.reduce(0, +) + CGFloat(words.count - 1) * attr(" ", f, ink).size().width
    }
    var w = total(f)
    if w > CGFloat(maxW) { f = font(size * Double(CGFloat(maxW) / w), .heavy); w = total(f) }
    let space = attr(" ", f, ink).size().width
    var x = -Double(w) / 2 / u
    for (i, word) in words.enumerated() {
        let a = attr(word.0, f, word.1)
        let ww = Double(a.size().width) / u
        let p = easeOut(prog(t, start + Double(i) * stagger, start + Double(i) * stagger + 0.45))
        drawText(a, cx: x + ww / 2, cy: cy, alpha: p * fade, scale: 0.96 + 0.04 * p, dy: (1 - p) * -34)
        x += ww + Double(space) / u
    }
}

func sceneHook(_ t: Double) {
    let a = win(t, 0.0, 3.5, 0.4)
    guard a > 0.002 else { return }
    lineOfWords([("Still", ink), ("paying", ink), ("monthly", ink)], size: 104, cy: 150, start: 0.15, stagger: 0.14, t: t, fade: a)
    lineOfWords([("to", ink), ("talk", cyan), ("to", ink)], size: 104, cy: 20, start: 0.7, stagger: 0.14, t: t, fade: a)
    lineOfWords([("your", ink), ("computer?", violet)], size: 104, cy: -110, start: 1.15, stagger: 0.16, t: t, fade: a)
}

// MARK: scene 2 - demo

struct Spoken { let word: String; let at: Double; let filler: Bool }
let spoken: [[Spoken]] = [
    [Spoken(word: "um", at: 4.55, filler: true), Spoken(word: "so", at: 4.75, filler: false),
     Spoken(word: "I", at: 4.95, filler: true), Spoken(word: "I", at: 5.15, filler: false),
     Spoken(word: "want", at: 5.35, filler: false), Spoken(word: "to", at: 5.55, filler: false),
     Spoken(word: "uh", at: 5.8, filler: true)],
    [Spoken(word: "meet", at: 6.1, filler: false), Spoken(word: "tuesday,", at: 6.35, filler: true),
     Spoken(word: "no", at: 6.75, filler: true), Spoken(word: "wait,", at: 6.95, filler: true),
     Spoken(word: "wednesday", at: 7.25, filler: false)],
]
let releaseT = 7.7, transcribeEnd = 8.15, polishEnd = 8.75

func speechBubble(_ t: Double, _ a: Double) {
    let fadeOut = 1 - easeInOut(prog(t, 9.4, 9.9))
    let alpha = a * fadeOut
    guard alpha > 0.002 else { return }
    drawText(attr("YOU SAY", font(24, .semibold), muted), cx: 0, cy: 445, alpha: alpha * easeOut(prog(t, 4.3, 4.7)))
    rrect(cx: 0, cy: 335, w: 900, h: 170, r: 36, fill: hex(0x2A2760, 0.75), stroke: NSColor.white.withAlphaComponent(0.10),
          alpha: alpha * easeOut(prog(t, 4.3, 4.7)), scale: 0.97 + 0.03 * easeOut(prog(t, 4.3, 4.7)))
    let f = font(42, .medium)
    var idx = 0
    for (li, line) in spoken.enumerated() {
        let sp = attr(" ", f, ink).size().width
        let widths = line.map { attr($0.word, f, ink).size().width }
        let total = widths.reduce(0, +) + sp * CGFloat(line.count - 1)
        var x = -Double(total) / 2 / u
        let cy = 335 + (li == 0 ? 36.0 : -36.0)
        for (i, s) in line.enumerated() {
            let ww = Double(widths[i]) / u
            let appear = easeOut(prog(t, s.at, s.at + 0.18))
            let strike = s.filler ? easeOut(prog(t, 7.95 + Double(idx) * 0.07, 7.95 + Double(idx) * 0.07 + 0.25)) : 0
            let col = s.filler ? NSColor(srgbRed: 0.91, green: 0.91, blue: 1, alpha: 1 - 0.65 * strike) : hex(0xEFEEFF)
            drawText(attr(s.word, f, col), cx: x + ww / 2, cy: cy, alpha: appear * alpha, dy: (1 - appear) * -14)
            if strike > 0 {
                rrect(cx: x + ww / 2, cy: cy + 2, w: ww * strike + 6, h: 4, r: 2, fill: red, alpha: alpha * appear)
            }
            x += ww + Double(sp) / u
            idx += 1
        }
    }
}

func hud(_ t: Double, _ a: Double) {
    let appear = easeOut(prog(t, 4.3, 4.65))
    let vanish = 1 - easeInOut(prog(t, polishEnd, polishEnd + 0.3))
    let alpha = a * appear * vanish
    guard alpha > 0.002 else { return }
    let listening = t < releaseT
    let wide = 640.0, narrow = 400.0
    let w = listening ? wide : wide + (narrow - wide) * easeInOut(prog(t, releaseT, releaseT + 0.3))
    let cy = -120.0
    rrect(cx: 0, cy: cy, w: w, h: 100, r: 50, fill: hex(0x25224F, 0.96), stroke: NSColor.white.withAlphaComponent(0.18),
          alpha: alpha, scale: 0.9 + 0.1 * appear, shadow: true)
    if listening {
        // bars + label, centred as a group
        let label = attr("Listening…  Release to finish", font(31, .medium), ink)
        let lw = Double(label.size().width) / u
        let groupW = 120.0 + 22.0 + lw
        let left = -groupW / 2
        let speaking = easeOut(prog(t, 4.45, 4.7)) * (1 - easeOut(prog(t, 7.45, 7.7)))
        for i in 0..<9 {
            let v = abs(sin(t * 11 + Double(i) * 0.9) * cos(t * 5.3 + Double(i) * 1.3))
            let level = speaking * (0.25 + 0.75 * v)
            let h = max(6.0, 56 * (0.18 + 0.82 * level))
            rrect(cx: left + 6 + Double(i) * 13.5, cy: cy, w: 9, h: h, r: 4.5, fill: red, alpha: alpha)
        }
        drawText(label, cx: left + 120 + 22 + lw / 2, cy: cy, alpha: alpha)
    } else {
        let text = t < transcribeEnd ? "Transcribing…" : "Polishing…"
        drawText(attr(text, font(31, .medium), ink), cx: 0, cy: cy, alpha: alpha)
    }
}

func fieldCard(_ t: Double, _ a: Double) {
    let appear = easeOut(prog(t, 3.35, 3.9))
    rrect(cx: 0, cy: 90, w: 880, h: 200, r: 32, fill: card, stroke: NSColor.white.withAlphaComponent(0.12),
          alpha: a * appear, scale: 0.96 + 0.04 * appear, shadow: true)
    for (i, c) in [hex(0xFF5F57), hex(0xFEBC2E), hex(0x28C840)].enumerated() {
        rrect(cx: -400 + Double(i) * 30, cy: 160, w: 16, h: 16, r: 8, fill: c, alpha: a * appear)
    }
    // caret blinks until the text lands
    if t < polishEnd {
        let on = Int(t * 2) % 2 == 0
        if on { rrect(cx: -380, cy: 80, w: 4, h: 62, r: 2, fill: cyan, alpha: a * appear) }
    }
    let pasted = easeBack(prog(t, polishEnd, polishEnd + 0.4))
    if pasted > 0 {
        let hl = easeOut(prog(t, polishEnd + 0.05, polishEnd + 0.7))
        rrect(cx: 0, cy: 80, w: 760 * hl, h: 80, r: 18, fill: violet.withAlphaComponent(0.28 * (1 - easeInOut(prog(t, polishEnd + 0.7, polishEnd + 1.3)))), alpha: a)
        drawText(attr("I want to meet on Wednesday.", font(54, .semibold), ink), cx: 0, cy: 80,
                 alpha: a * clamp(pasted), scale: 0.94 + 0.06 * pasted)
    }
}

func keycap(_ t: Double, _ a: Double) {
    let appear = easeOut(prog(t, 3.5, 4.0))
    let press = easeInOut(prog(t, 4.2, 4.35)) - easeInOut(prog(t, releaseT, releaseT + 0.15))
    let cy = -270.0
    if press > 0.01 {
        let ph = (t * 1.4).truncatingRemainder(dividingBy: 1)
        rrect(cx: 0, cy: cy, w: 150, h: 150, r: 34, stroke: violet.withAlphaComponent(0.6 * (1 - ph)), lw: 5,
              alpha: a * press, scale: 1 + 0.45 * ph)
    }
    let fill = press > 0.5 ? hex(0x6A5CF0) : hex(0x2D2A66)
    rrect(cx: 0, cy: cy - 8 * press, w: 150, h: 150, r: 34, fill: hex(0x0E0C2B), alpha: a * appear, dy: -8 * (1 - press))
    rrect(cx: 0, cy: cy, w: 150, h: 150, r: 34, fill: fill, stroke: NSColor.white.withAlphaComponent(0.2),
          alpha: a * appear, scale: 1 - 0.04 * press, dy: -10 * press + (1 - appear) * -20)
    drawText(attr("⌥", font(76, .semibold), ink), cx: 0, cy: cy + 8, alpha: a * appear, scale: 1 - 0.04 * press, dy: -10 * press)
    drawText(attr("Right", font(22, .semibold), press > 0.5 ? ink : muted), cx: 0, cy: cy - 52, alpha: a * appear, dy: -10 * press)

    let c1 = a * appear * (1 - easeOut(prog(t, 7.6, 7.9)))
    drawText(attr("Hold to talk", font(34, .semibold), muted), cx: 0, cy: -400, alpha: c1)
    drawText(attr("Pasted into any app", font(34, .semibold), cyan), cx: 0, cy: -400,
             alpha: a * easeOut(prog(t, polishEnd + 0.1, polishEnd + 0.5)), dy: (1 - easeOut(prog(t, polishEnd + 0.1, polishEnd + 0.5))) * -12)
}

func sceneDemo(_ t: Double) {
    let a = win(t, 3.3, 10.6, 0.4)
    guard a > 0.002 else { return }
    speechBubble(t, a)
    fieldCard(t, a)
    hud(t, a)
    keycap(t, a)
}

// MARK: feature tour (full cut only; each scene gets a local t starting at 0)

func width(_ a: NSAttributedString) -> Double { Double(a.size().width) / u }

/// Coloured runs as one string, shrunk to fit `maxW` design units; `reveal` limits the visible characters (typing).
func runs(_ rs: [(String, NSColor)], _ size: Double, _ weight: NSFont.Weight = .semibold, mono: Bool = false,
          maxW: Double = 880, reveal: Int = .max) -> NSAttributedString {
    func make(_ sz: Double, _ limit: Int) -> NSAttributedString {
        let f = mono ? NSFont.monospacedSystemFont(ofSize: CGFloat(sz * u), weight: weight) : font(sz, weight)
        let s = NSMutableAttributedString()
        var left = limit
        for (text, c) in rs where left > 0 {
            s.append(attr(String(text.prefix(left)), f, c))
            left -= text.count
        }
        return s
    }
    let w = width(make(size, .max))
    let sz = w > maxW ? size * maxW / w : size
    return make(sz, reveal)
}
func fit(_ s: String, _ size: Double, _ weight: NSFont.Weight, _ c: NSColor, maxW: Double) -> NSAttributedString {
    runs([(s, c)], size, weight, maxW: maxW)
}
func drawLeft(_ a: NSAttributedString, x: Double, cy: Double, alpha: Double, dx: Double = 0) {
    drawText(a, cx: x + width(a) / 2, cy: cy, alpha: alpha, dx: dx)
}

func sceneTitle(_ eyebrow: String, _ words: [(String, NSColor)], t: Double, a: Double) {
    let p = easeOut(prog(t, 0.1, 0.5))
    drawText(fit(eyebrow, 24, .semibold, cyan, maxW: 880), cx: 0, cy: 470, alpha: a * p, dy: (1 - p) * -10)
    lineOfWords(words, size: 68, cy: 395, start: 0.2, stagger: 0.1, t: t, fade: a)
}

func key(_ label: String, cx: Double, cy: Double, w: Double, press: Double, alpha: Double) {
    rrect(cx: cx, cy: cy - 7, w: w, h: 90, r: 22, fill: hex(0x0E0C2B), alpha: alpha)
    rrect(cx: cx, cy: cy, w: w, h: 90, r: 22, fill: press > 0.5 ? hex(0x6A5CF0) : hex(0x2D2A66),
          stroke: NSColor.white.withAlphaComponent(0.2), alpha: alpha, dy: -7 * press)
    drawText(fit(label, 34, .semibold, ink, maxW: w - 24), cx: cx, cy: cy, alpha: alpha, dy: -7 * press)
}

func bubble(_ text: String, label: String, cy: Double, t: Double, start: Double, a: Double) {
    let p = easeOut(prog(t, start, start + 0.4))
    drawText(attr(label, font(22, .semibold), muted), cx: 0, cy: cy + 78, alpha: a * p)
    rrect(cx: 0, cy: cy, w: 880, h: 104, r: 36, fill: hex(0x2A2760, 0.75), stroke: NSColor.white.withAlphaComponent(0.10),
          alpha: a * p, scale: 0.97 + 0.03 * p)
    let s = fit(text, 38, .medium, hex(0xEFEEFF), maxW: 820)
    drawText(s, cx: 0, cy: cy, alpha: a * easeOut(prog(t, start + 0.15, start + 0.6)), dy: (1 - p) * -12)
}

func featStart(_ t: Double) {
    let a = win(t, 0, 5.4)
    guard a > 0.002 else { return }
    sceneTitle("HANDS ON OR HANDS FREE", [("Four", ink), ("ways", ink), ("to", ink), ("start", cyan)], t: t, a: a)
    let rows: [(String, String, String)] = [
        ("Right ⌥", "Hold to talk", "Release when you're done"),
        ("⌥  ⌥", "Double-tap for hands-free", "Stops by itself when you pause"),
        ("⌃ Space", "Press to start, again to stop", "Esc cancels at any time"),
        ("mic", "Say “Hey Murmur”", "Optional wake word"),
    ]
    for (i, r) in rows.enumerated() {
        let p = easeOut(prog(t, 0.6 + Double(i) * 0.45, 1.1 + Double(i) * 0.45))
        let cy = 235.0 - Double(i) * 150, dx = (1 - p) * 90
        rrect(cx: 0, cy: cy, w: 880, h: 120, r: 36, fill: hex(0x25224F, 0.9), stroke: NSColor.white.withAlphaComponent(0.12),
              alpha: a * p, dx: dx, shadow: true)
        rrect(cx: -330, cy: cy, w: 170, h: 80, r: 20, fill: i % 2 == 0 ? violet : hex(0x3AA8D6), alpha: a * p, dx: dx)
        if r.0 == "mic" { symbol("waveform", size: 36, cx: -330, cy: cy, alpha: a * p, dx: dx) }
        else { drawText(fit(r.0, 32, .semibold, ink, maxW: 150), cx: -330, cy: cy, alpha: a * p, dx: dx) }
        drawLeft(fit(r.1, 38, .semibold, ink, maxW: 620), x: -215, cy: cy + 18, alpha: a * p, dx: dx)
        drawLeft(fit(r.2, 27, .medium, muted, maxW: 620), x: -215, cy: cy - 24, alpha: a * p, dx: dx)
    }
}

func featEdit(_ t: Double) {
    let a = win(t, 0, 6.0)
    guard a > 0.002 else { return }
    sceneTitle("SELECT  ·  ⌃⌥SPACE  ·  SPEAK", [("Edit", ink), ("by", ink), ("voice", cyan)], t: t, a: a)
    let appear = easeOut(prog(t, 0.4, 0.9))
    rrect(cx: 0, cy: 165, w: 880, h: 210, r: 32, fill: card, stroke: NSColor.white.withAlphaComponent(0.12),
          alpha: a * appear, scale: 0.96 + 0.04 * appear, shadow: true)
    for (i, c) in [hex(0xFF5F57), hex(0xFEBC2E), hex(0x28C840)].enumerated() {
        rrect(cx: -400 + Double(i) * 30, cy: 240, w: 16, h: 16, r: 8, fill: c, alpha: a * appear)
    }
    let swap = easeInOut(prog(t, 3.9, 4.3))
    let old = fit("Send me the report by 5.", 50, .semibold, ink, maxW: 760)
    let sel = easeOut(prog(t, 1.0, 1.5)) * (1 - swap)
    if sel > 0 { rrect(cx: 0, cy: 150, w: (width(old) + 30) * sel, h: 76, r: 12, fill: hex(0x3B6FE0, 0.6), alpha: a) }
    drawText(old, cx: 0, cy: 150, alpha: a * appear * (1 - swap))
    let pop = 0.96 + 0.04 * easeBack(prog(t, 3.9, 4.4))
    drawText(fit("Hi! Could you send me the report by 5?", 44, .semibold, ink, maxW: 800), cx: 0, cy: 180, alpha: a * swap, scale: pop)
    drawText(fit("Thanks so much.", 44, .semibold, ink, maxW: 800), cx: 0, cy: 122, alpha: a * swap, scale: pop)

    let keysP = easeOut(prog(t, 1.4, 1.8))
    let press = easeInOut(prog(t, 1.9, 2.05)) - easeInOut(prog(t, 3.5, 3.65))
    key("⌃", cx: -166, cy: -20, w: 100, press: press, alpha: a * keysP)
    key("⌥", cx: -50, cy: -20, w: 100, press: press, alpha: a * keysP)
    key("Space", cx: 116, cy: -20, w: 200, press: press, alpha: a * keysP)
    bubble("“make this friendlier”", label: "YOU SAY", cy: -210, t: t, start: 2.2, a: a * (1 - easeInOut(prog(t, 4.2, 4.6))))
    let done = easeOut(prog(t, 4.4, 4.8))
    drawText(attr("Replaced right where it was", font(36, .semibold), cyan), cx: 0, cy: -210, alpha: a * done, dy: (1 - done) * -12)
}

func featRules(_ t: Double) {
    let a = win(t, 0, 6.2)
    guard a > 0.002 else { return }
    sceneTitle("ONE PLAIN TEXT FILE", [("Your", ink), ("words,", ink), ("your", ink), ("rules", cyan)], t: t, a: a)
    let appear = easeOut(prog(t, 0.4, 0.9))
    rrect(cx: 0, cy: 170, w: 880, h: 250 * ky + 10, r: 28, fill: hex(0x120F33), stroke: NSColor.white.withAlphaComponent(0.14),
          alpha: a * appear, scale: 0.96 + 0.04 * appear, shadow: true)
    drawLeft(runs([("rules.md", dim)], 24, .medium, mono: true), x: -400, cy: 262, alpha: a * appear)
    let lines: [[(String, NSColor)]] = [
        [("\"git hub\"", cyan), ("  ->  ", dim), ("\"GitHub\"", ink)],
        [("\"sign off\"", cyan), ("  =>  ", dim), ("\"Best regards,\"", ink)],
        [("vocabulary: ", violet), ("Kubernetes, Sriram", ink)],
    ]
    for (i, l) in lines.enumerated() {
        let n = l.map(\.0.count).reduce(0, +)
        let shown = Int(Double(n) * prog(t, 0.9 + Double(i) * 0.6, 1.4 + Double(i) * 0.6))
        guard shown > 0 else { continue }
        drawLeft(runs(l, 32, .medium, mono: true, maxW: 800, reveal: shown), x: -400, cy: 205 - Double(i) * 58, alpha: a)
    }
    bubble("“deploy to kubernetes, push to git hub, sign off”", label: "YOU SAY", cy: -55, t: t, start: 2.9, a: a)
    let r = easeOut(prog(t, 3.8, 4.3))
    symbol("arrow.down", size: 30, cx: 0, cy: -150, alpha: a * r)
    rrect(cx: 0, cy: -245, w: 880, h: 110, r: 36, fill: violet.withAlphaComponent(0.22), stroke: violet.withAlphaComponent(0.6),
          alpha: a * r, scale: 0.96 + 0.04 * r)
    drawText(runs([("Deploy to ", ink), ("Kubernetes", cyan), (", push to ", ink), ("GitHub", cyan), (". ", ink), ("Best regards,", cyan)],
                  38, .semibold, maxW: 820), cx: 0, cy: -245, alpha: a * r)
}

func featTone(_ t: Double) {
    let a = win(t, 0, 5.2)
    guard a > 0.002 else { return }
    sceneTitle("PER-APP RULES", [("The", ink), ("right", ink), ("tone,", ink), ("per", ink), ("app", cyan)], t: t, a: a)
    bubble("“tell sam the launch moved to friday”", label: "YOU SAY", cy: 245, t: t, start: 0.5, a: a)
    let apps: [(String, NSColor, String, String)] = [
        ("Mail", violet, "Hi Sam, the launch has moved to Friday.", "[Mail]  Use a formal, polite tone."),
        ("Slack", hex(0x3AA8D6), "Heads up: launch moved to Friday!", "[Slack]  Keep it short and casual."),
    ]
    for (i, app) in apps.enumerated() {
        let p = easeOut(prog(t, 1.3 + Double(i) * 0.8, 1.8 + Double(i) * 0.8))
        let cy = 60.0 - Double(i) * 200, dx = (1 - p) * 90
        rrect(cx: 0, cy: cy, w: 880, h: 160, r: 32, fill: card, stroke: NSColor.white.withAlphaComponent(0.12),
              alpha: a * p, dx: dx, shadow: true)
        rrect(cx: -355, cy: cy + 42, w: 130, h: 44, r: 22, fill: app.1, alpha: a * p, dx: dx)
        drawText(attr(app.0, font(26, .bold), ink), cx: -355, cy: cy + 42, alpha: a * p, dx: dx)
        drawLeft(fit(app.3, 24, .medium, dim, maxW: 520), x: -270, cy: cy + 42, alpha: a * p, dx: dx)
        drawLeft(fit(app.2, 40, .semibold, ink, maxW: 820), x: -410, cy: cy - 25, alpha: a * p, dx: dx)
    }
}

func featGrid(_ t: Double) {
    let a = win(t, 0, 4.6)
    guard a > 0.002 else { return }
    sceneTitle("BUILT IN", [("And", ink), ("the", ink), ("little", ink), ("things", cyan)], t: t, a: a)
    let chips: [(String, String)] = [
        ("macwindow.on.rectangle", "Works in any app"), ("globe", "Speaks your language"),
        ("lock.fill", "Skips password fields"), ("return", "Say “new line”"),
        ("doc.on.clipboard", "Restores your clipboard"), ("clock.arrow.circlepath", "Optional history"),
    ]
    for (i, c) in chips.enumerated() {
        let p = easeBack(prog(t, 0.5 + Double(i) * 0.2, 1.0 + Double(i) * 0.2))
        let cx = i % 2 == 0 ? -222.0 : 222.0, cy = 205.0 - Double(i / 2) * 170
        rrect(cx: cx, cy: cy, w: 424, h: 150, r: 32, fill: hex(0x25224F, 0.9), stroke: NSColor.white.withAlphaComponent(0.12),
              alpha: a * clamp(p), scale: 0.85 + 0.15 * p, shadow: true)
        rrect(cx: cx, cy: cy + 30, w: 60, h: 60, r: 18, fill: i % 2 == 0 ? violet : hex(0x3AA8D6), alpha: a * clamp(p))
        symbol(c.0, size: 28, cx: cx, cy: cy + 30, alpha: a * clamp(p))
        drawText(fit(c.1, 32, .semibold, ink, maxW: 380), cx: cx, cy: cy - 35, alpha: a * clamp(p))
    }
}

func sceneFeatures(_ t: Double) {
    guard t > 0, t < FEAT_LEN else { return }
    featStart(t)
    featEdit(t - 5.4)
    featRules(t - 11.4)
    featTone(t - 17.6)
    featGrid(t - 22.8)
}

// MARK: scene 3 - proof

func sceneProof(_ t: Double) {
    let a = win(t, 10.45, 15.9, 0.4)
    guard a > 0.002 else { return }
    lineOfWords([("Dictation", ink), ("that's", ink), ("yours.", cyan)], size: 76, cy: 410, start: 10.6, stagger: 0.12, t: t, fade: a)
    let rows: [(String, String)] = [
        ("gift.fill", "Free. No subscription."),
        ("chevron.left.forwardslash.chevron.right", "Open source, MIT"),
        ("lock.shield.fill", "Audio never leaves your Mac"),
        ("person.crop.circle.badge.xmark", "No account. No sign-up."),
    ]
    for (i, row) in rows.enumerated() {
        let p = easeOut(prog(t, 11.05 + Double(i) * 0.55, 11.05 + Double(i) * 0.55 + 0.5))
        let cy = 235.0 - Double(i) * 150
        let dx = (1 - p) * 90
        rrect(cx: 0, cy: cy, w: 880, h: 120, r: 36, fill: hex(0x25224F, 0.9), stroke: NSColor.white.withAlphaComponent(0.12),
              alpha: a * p, dx: dx, shadow: true)
        rrect(cx: -360, cy: cy, w: 76, h: 76, r: 22, fill: i % 2 == 0 ? violet : hex(0x3AA8D6), alpha: a * p, dx: dx)
        symbol(row.0, size: 36, cx: -360, cy: cy, alpha: a * p, dx: dx)
        drawText(attr(row.1, font(43, .semibold), ink), cx: -305 + Double(attr(row.1, font(43, .semibold), ink).size().width) / u / 2,
                 cy: cy, alpha: a * p, dx: dx)
    }
}

// MARK: scene 4 - call to action

func sceneCTA(_ t: Double) {
    let a = clamp(easeOut(prog(t, 15.7, 16.2)))
    guard a > 0.002 else { return }
    let pop = easeBack(prog(t, 15.9, 16.55))
    glow(cx: Double(W) / 2, cy: Double(Y(250)), radius: 330 * u, color: violet, alpha: 0.45 * a)
    if let icon {
        let size = 250 * u * pop
        ctx.saveGState()
        ctx.setAlpha(CGFloat(a))
        ctx.setShadow(offset: CGSize(width: 0, height: -16 * u), blur: 40 * u, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        icon.draw(in: NSRect(x: X(0) - size / 2, y: Y(250) - size / 2, width: size, height: size))
        ctx.restoreGState()
    }
    let up = { (s: Double, d: Double) in easeOut(prog(t, s, s + d)) }
    drawText(attr("Murmur", font(128, .heavy), ink), cx: 0, cy: 55, alpha: a * up(16.25, 0.5), dy: (1 - up(16.25, 0.5)) * -30)
    drawText(attr("Free dictation for your Mac.", font(46, .medium), muted), cx: 0, cy: -45,
             alpha: a * up(16.55, 0.5), dy: (1 - up(16.55, 0.5)) * -24)
    let urlP = up(16.9, 0.5)
    let pulse = 1 + 0.012 * sin(t * 3)
    rrect(cx: 0, cy: -165, w: 800, h: 104, r: 52, fill: hex(0x6A5CF0), stroke: NSColor.white.withAlphaComponent(0.35), lw: 2,
          alpha: a * urlP, scale: (0.94 + 0.06 * urlP) * pulse, shadow: true)
    drawText(attr("github.com/vinoth12940/Murmur", font(41, .semibold), ink), cx: 0, cy: -165, alpha: a * urlP, scale: pulse)
    drawText(attr("macOS 26  ·  Apple Silicon  ·  MIT licensed", font(28, .medium), dim), cx: 0, cy: -275,
             alpha: a * up(17.3, 0.5))
}

// MARK: main

func render(_ t: Double) {
    background(t)
    sceneHook(t)
    sceneDemo(t)
    if full { sceneFeatures(t - FEAT0) }
    sceneProof(t - shift)
    sceneCTA(t - shift)
}

let out = FileHandle.standardOutput
for f in 0..<Int(DURATION * FPS) {
    render(Double(f) / FPS)
    out.write(Data(bytes: ctx.data!, count: W * H * 4))
}
