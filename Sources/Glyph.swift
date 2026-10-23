import AppKit

/// The Murmur mark: a short voice waveform that resolves into a text caret.
/// Same geometry as the app icon (Tools/make_icon.swift), drawn as a template for the menu bar.
enum Glyph {
    static let barHeights: [CGFloat] = [0.34, 0.62, 1.0, 0.62]

    static func menuBarImage(recording: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let color: NSColor = recording ? .systemRed : .black
            color.setFill()
            let barW: CGFloat = 2.4, gap: CGFloat = 2.0
            let heights = barHeights
            let count = CGFloat(heights.count)
            let caretGap: CGFloat = 3.2
            let total = count * barW + (count - 1) * gap + caretGap + barW * 0.8
            var x = (rect.width - total) / 2
            let maxH = rect.height - 2
            for h in heights {
                let bh = maxH * h * 0.78
                NSBezierPath(roundedRect: NSRect(x: x, y: (rect.height - bh) / 2, width: barW, height: bh),
                             xRadius: barW / 2, yRadius: barW / 2).fill()
                x += barW + gap
            }
            x += caretGap - gap
            let caretW = barW * 0.8
            NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: caretW, height: maxH),
                         xRadius: caretW / 2, yRadius: caretW / 2).fill()
            return true
        }
        image.isTemplate = !recording
        return image
    }
}
