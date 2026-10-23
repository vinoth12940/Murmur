import AppKit
import CoreGraphics

/// Modifier keys that can be used as the push-to-talk trigger. Modifier-only keys never collide
/// with another app's shortcuts, which is why they work better than a key combination.
enum TriggerKey: String, CaseIterable {
    case rightOption, fn, rightCommand, rightControl

    var title: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .fn: return "Fn / Globe (🌐)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        }
    }
    var shortName: String {
        switch self {
        case .rightOption: return "Right ⌥"
        case .fn: return "Fn"
        case .rightCommand: return "Right ⌘"
        case .rightControl: return "Right ⌃"
        }
    }
    var keyCode: Int64 {
        switch self {
        case .rightOption: return 61
        case .fn: return 63
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }
    /// Device-dependent flag bit that is set only while this exact (left/right) key is down.
    var flagMask: UInt64 {
        switch self {
        case .rightOption: return 0x40
        case .fn: return CGEventFlags.maskSecondaryFn.rawValue
        case .rightCommand: return 0x10
        case .rightControl: return 0x2000
        }
    }
}

/// Listens (read-only) for the trigger key going down/up and for any other key press.
/// Needs the Input Monitoring permission; `start()` returns false until it is granted.
final class KeyMonitor {
    var trigger: TriggerKey = .rightOption
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onOtherKey: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    var isRunning: Bool { tap != nil }

    static var hasPermission: Bool { CGPreflightListenEventAccess() }
    static func requestPermission() { _ = CGRequestListenEventAccess() }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<KeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            onOtherKey?()
        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == trigger.keyCode {
                let down = event.flags.rawValue & trigger.flagMask != 0
                guard down != isDown else { return }
                isDown = down
                down ? onDown?() : onUp?()
            } else {
                // Another modifier pressed while the trigger is held: treat as a shortcut, not dictation.
                if isDown { onOtherKey?() }
            }
        default: break
        }
    }
}
