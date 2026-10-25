import Foundation

/// Tiny diagnostic log at ~/Library/Logs/Murmur.log (local only). Records app events. What the
/// wake-word recognizer heard is written only when the hidden "verboseLog" default is on.
/// The file is capped: past `maxBytes` it moves to Murmur.log.1 (one generation is kept).
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Murmur.log")
    static let maxBytes = 512_000
    private static let queue = DispatchQueue(label: "murmur.log")

    /// Whether to log speech content heard by the wake-word listener. Off unless the user opts in.
    static var verbose: Bool { UserDefaults.standard.bool(forKey: "verboseLog") }

    static func write(_ message: String) {
        queue.async {
            rotateIfNeeded(url: url, maxBytes: maxBytes)
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Moves `url` to `<url>.1` (replacing any older copy) once it is larger than `maxBytes`.
    static func rotateIfNeeded(url: URL, maxBytes: Int) {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size > maxBytes else { return }
        let old = url.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
    }

    /// The last `count` lines of the log, for the diagnostics report.
    static func tail(_ count: Int = 40) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).joined(separator: "\n")
    }
}
