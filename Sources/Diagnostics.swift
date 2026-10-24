import Foundation

/// Builds the text behind "Copy Diagnostics". It is shown to the user by being copied to their clipboard;
/// nothing is sent anywhere. Contains no transcripts, and the home folder path is replaced by "~".
enum Diagnostics {
    static func report(state: String, settings: [String: String], logTail: String,
                       permissions: [String: String] = [:]) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "Murmur \(version) (\(build))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "State: \(state)",
            "",
            "Permissions:",
        ]
        lines += permissions.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }
        lines += ["", "Settings:"]
        lines += settings.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }
        lines += ["", "Recent log:", logTail]
        return scrub(lines.joined(separator: "\n"))
    }

    static func scrub(_ text: String) -> String {
        text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
