import AppKit

/// Small floating pill near the bottom of the screen showing listening / working / result state.
/// It never takes focus, so the field you're dictating into stays active.
final class HUD {
    private let panel: NSPanel
    private let bars = BarsView()
    private let label = NSTextField(labelWithString: "")
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 230, height: 46),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let blur = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 23
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        bars.translatesAutoresizingMaskIntoConstraints = false
        bars.widthAnchor.constraint(equalToConstant: 52).isActive = true
        bars.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let stack = NSStackView(views: [bars, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: blur.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: blur.trailingAnchor, constant: -16),
        ])
        panel.contentView = blur
    }

    func showListening(hint: String) {
        hideTask?.cancel()
        bars.isHidden = false
        bars.reset()
        label.stringValue = "Listening…  \(hint)"
        present()
    }

    /// Live preview while speaking: the tail of what has been recognised so far, next to the level bars.
    func showLive(_ text: String) {
        hideTask?.cancel()
        bars.isHidden = false
        let tail = text.count > 52 ? "…" + text.suffix(52) : text
        label.stringValue = tail.isEmpty ? "Listening…" : tail
        present()
    }

    func updateLevel(_ level: Float) {
        bars.push(CGFloat(level))
    }

    func showBusy(_ text: String) {
        hideTask?.cancel()
        bars.isHidden = true
        label.stringValue = text
        present()
    }

    func flash(_ text: String, seconds: Double = 2.2) {
        hideTask?.cancel()
        bars.isHidden = true
        label.stringValue = text
        present()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.hide() }
        }
    }

    func hide() {
        hideTask?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; panel.animator().alphaValue = 0 },
                                             completionHandler: { [panel] in
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }

    private func present() {
        label.sizeToFit()
        let width = max(150, min(460, label.frame.width + (bars.isHidden ? 0 : 62) + 44))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrame(NSRect(x: area.midX - width / 2, y: area.minY + 28, width: width, height: 46), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }
}

private final class BarsView: NSView {
    private var history = [CGFloat](repeating: 0, count: 9)

    func reset() { history = [CGFloat](repeating: 0, count: history.count); needsDisplay = true }

    func push(_ level: CGFloat) {
        history.removeFirst()
        history.append(level)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        let n = CGFloat(history.count), gap: CGFloat = 2
        let w = (bounds.width - gap * (n - 1)) / n
        for (i, level) in history.enumerated() {
            let h = max(4, bounds.height * (0.18 + 0.82 * level))
            let rect = NSRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            NSBezierPath(roundedRect: rect, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }
}
