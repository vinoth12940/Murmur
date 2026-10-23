import Foundation

/// Tiny diagnostic log at ~/Library/Logs/Murmur.log (local only). Records app events and,
/// for the wake word, the first characters of what the recognizer heard.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Murmur.log")
    private static let queue = DispatchQueue(label: "murmur.log")

    static func write(_ message: String) {
        queue.async {
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
}
