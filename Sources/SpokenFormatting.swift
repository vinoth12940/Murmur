import Foundation

/// Turns spoken layout commands into real characters: "new paragraph" and "new line".
/// Works on the cleaned text, so it also swallows the commas and full stops the cleanup put around the phrase.
enum SpokenFormatting {
    static func apply(_ text: String) -> String {
        var result = text
        // Paragraphs first so "new paragraph" is never half-eaten by the "new line" rule.
        for (phrase, replacement) in [("new paragraph", "\n\n"), ("new line|newline", "\n")] {
            let pattern = "[,;]?[ \\t]*\\b(?:\(phrase))\\b[.,;:!?]*[ \\t]*"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
        return result
    }
}
