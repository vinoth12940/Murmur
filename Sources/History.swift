import Foundation

struct HistoryEntry: Codable, Equatable {
    var date: Date
    var app: String
    var text: String
}

/// Optional local dictation history: JSON Lines in Application Support, readable only by the user,
/// trimmed to the newest `limit` entries. Off unless the user turns it on; never leaves the Mac.
final class History {
    static let shared = History(fileURL: Rules.directory.appendingPathComponent("history.jsonl"))

    let fileURL: URL
    let limit: Int

    init(fileURL: URL, limit: Int = 200) {
        self.fileURL = fileURL
        self.limit = limit
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Oldest first. Lines that cannot be decoded are skipped.
    private func load() -> [HistoryEntry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Self.decoder.decode(HistoryEntry.self, from: Data($0.utf8)) }
    }

    func append(_ entry: HistoryEntry) {
        let entries = Array((load() + [entry]).suffix(limit))
        let lines = entries.compactMap { try? Self.encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + "\n"
        // Atomic replace is preferred; some locations refuse the temporary file, so fall back to a direct write.
        if (try? text.write(to: fileURL, atomically: true, encoding: .utf8)) == nil {
            try? text.write(to: fileURL, atomically: false, encoding: .utf8)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Newest first.
    func recent(_ count: Int) -> [HistoryEntry] {
        Array(load().suffix(count).reversed())
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
