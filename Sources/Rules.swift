import Foundation

/// The user's cleanup rules, kept in a plain text file the user edits.
///
/// - `# comment` and blank lines are ignored.
/// - `"heard" -> "written"`: literal replacement, also shown to the model and enforced afterwards.
/// - `"phrase" => "text"`: a snippet; say the phrase and it expands to the text (`\n` = new line).
/// - `vocabulary: Murmur, Kubernetes`: words the speech recognizer should expect.
/// - `[Mail]` / `[com.apple.mail]`: lines below apply only while that app is in front
///   (`[default]` ends the section). Lines above any header apply everywhere.
/// - Any other line is a free-form instruction for the language model.
struct Rules {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmur", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("rules.md")
    /// A rules file larger than this is read only up to this many characters.
    static let maxCharacters = 200_000

    static let template = """
    # Murmur cleanup rules
    #
    # Everything here is applied each time you dictate. Lines starting with # are comments.
    # Edit freely; changes apply to the next dictation.
    #
    # 1) Plain-language rules (sent to the on-device model when cleanup is on):
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

    # 3) Snippets: say the phrase, get the text. Use \\n for a new line.
    # "my email" => "me@example.com"
    # "sign off" => "Best regards,\\nYour Name"

    # 4) Words the recognizer should expect (names, products, jargon):
    # vocabulary: Murmur, Kubernetes

    # 5) Per-app rules: everything below a [App Name] or [bundle.id] line applies only in that app.
    # [Mail]
    # Use a formal, polite tone.
    # [Slack]
    # Keep it short and casual.
    # [default]
    """

    var instructions: [String] = []
    var replacements: [(from: String, to: String)] = []
    var snippets: [(phrase: String, text: String)] = []
    var vocabularyTerms: [String] = []

    /// Terms for the speech recognizer: the explicit `vocabulary:` lines plus every replacement target.
    var vocabulary: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in vocabularyTerms + replacements.map(\.to) {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    static func ensureFileExists() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            try? template.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Loads the user's file. `appNames` are the names (display name, bundle id) of the app being dictated into.
    static func load(appNames: [String] = []) -> Rules {
        ensureFileExists()
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return Rules() }
        return parse(text, appNames: appNames)
    }

    /// Pure parser. Never fails: malformed lines become instructions or are skipped.
    static func parse(_ text: String, appNames: [String] = []) -> Rules {
        var rules = Rules()
        let wanted = Set(appNames.map { $0.lowercased() })
        var sectionActive = true
        for raw in text.prefix(maxCharacters).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("["), line.hasSuffix("]"), line.count > 2 {
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                sectionActive = name == "default" || name == "all" || wanted.contains(name)
                continue
            }
            guard sectionActive else { continue }

            if line.lowercased().hasPrefix("vocabulary:") {
                let list = line.dropFirst("vocabulary:".count)
                rules.vocabularyTerms += list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else if let pair = parseSnippet(line) {
                rules.snippets.append(pair)
            } else if let pair = parseReplacement(line) {
                rules.replacements.append(pair)
            } else if line.contains("->") || line.contains("=>") {
                continue // a malformed replacement or snippet is skipped, not sent to the model as an instruction
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

    /// `"phrase" => "text"`; recognised only when `=>` comes before any `->`.
    private static func parseSnippet(_ line: String) -> (String, String)? {
        guard let fat = line.range(of: "=>") else { return nil }
        if let arrow = line.range(of: "->"), arrow.lowerBound < fat.lowerBound { return nil }
        let phrase = unquote(String(line[..<fat.lowerBound]))
        let body = unquote(String(line[fat.upperBound...])).replacingOccurrences(of: "\\n", with: "\n")
        return phrase.isEmpty || body.isEmpty ? nil : (phrase, body)
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        let quotes: Set<Character> = ["\"", "“", "”", "'"]
        if let f = t.first, quotes.contains(f) { t.removeFirst() }
        if let l = t.last, quotes.contains(l) { t.removeLast() }
        return t
    }

    /// Regex for a phrase where any run of whitespace matches any other ("open ai" also matches "open  AI").
    private static func phrasePattern(_ phrase: String) -> String {
        phrase.split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "\\s+")
    }

    func applyReplacements(to text: String) -> String {
        var result = text
        for (from, to) in replacements {
            let pattern = "\\b" + Self.phrasePattern(from) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: to))
        }
        return result
    }

    /// Expands snippet phrases. A phrase at the very end also swallows the sentence punctuation
    /// the cleanup may have added after it ("my email." becomes just the email).
    func applySnippets(to text: String) -> String {
        var result = text
        for (phrase, body) in snippets {
            let core = "\\b" + Self.phrasePattern(phrase) + "\\b"
            let template = NSRegularExpression.escapedTemplate(for: body)
            for pattern in [core + "[.,;:!?]*\\s*$", core] {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
            }
        }
        return result
    }
}
