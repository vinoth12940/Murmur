import AppKit
import AVFoundation

enum PermissionState {
    case granted, missing, notDetermined

    var label: String {
        switch self {
        case .granted: return "Allowed"
        case .missing: return "Not allowed"
        case .notDetermined: return "Not asked yet"
        }
    }
}

/// Live status of the privacy permissions Murmur uses, plus shortcuts to the right System Settings pane.
enum Permissions {
    static var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .missing
        }
    }
    static var inputMonitoring: PermissionState { KeyMonitor.hasPermission ? .granted : .missing }
    static var accessibility: PermissionState { Paster.hasAccessibility ? .granted : .missing }

    static var allGranted: Bool {
        [microphone, inputMonitoring, accessibility].allSatisfy { $0 == .granted }
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case inputMonitoring = "Privacy_ListenEvent"
        case accessibility = "Privacy_Accessibility"
    }

    static func openSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
