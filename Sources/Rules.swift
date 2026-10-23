import Foundation

/// The user's cleanup rules, kept in a plain text file the user edits.
/// Free-form lines are instructions for the language model. Lines of the form
/// `"heard" -> "written"` are also applied literally after cleanup, so they hold even if
/// the model misses them.
struct Rules {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmur", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("rules.md")

    static let template = """
    # Murmur cleanup rules
    #
    # Everything here is applied each time you dictate with "Clean up with Apple Intelligence" on.
    # Lines starting with # are comments. Edit freely; changes apply to the next dictation.
    #
    # 1) Plain-language rules (sent to the on-device model):
    Write numbers under ten as words and everything else as digits.
    Keep a casual tone; never add words I did not say.
    Use American English spelling.

    # 2) Exact replacements, written "heard" -> "written" (case-insensitive, whole words):
    "open ai" -> "OpenAI"
    "chat gpt" -> "ChatGPT"
    "mac os" -> "macOS"
    "i phone" -> "iPhone"
    "java script" -> "JavaScript"
    "git hub" -> "GitHub"
    """

    var instructions: [String] = []
    var replacements: [(from: String, to: String)] = []

    static func ensureFileExists() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            try? template.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    static func load() -> Rules {
        ensureFileExists()
        var rules = Rules()
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return rules }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let pair = parseReplacement(line) {
                rules.replacements.append(pair)
            } else {
                rules.instructions.append(line)
            }
        }
        return rules
    }

    private static func parseReplacement(_ line: String) -> (String, String)? {
        guard let arrow = line.range(of: "->") else { return nil }
        let from = unquote(String(line[..<arrow.lowerBound]))
        let to = unquote(String(line[arrow.upperBound...]))
        return from.isEmpty ? nil : (from, to)
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        let quotes: Set<Character> = ["\"", "“", "”", "'"]
        if let f = t.first, quotes.contains(f) { t.removeFirst() }
        if let l = t.last, quotes.contains(l) { t.removeLast() }
        return t
    }

    func applyReplacements(to text: String) -> String {
        var result = text
        for (from, to) in replacements {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: from).replacingOccurrences(of: "\\ ", with: "\\s+") + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: to))
        }
        return result
    }
}
