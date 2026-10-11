import Foundation

/// Finds and removes a piece of text across a document's pages.
///
/// Matching is forgiving about whitespace (a phrase copied from one line still matches when
/// it wraps differently elsewhere), and can optionally treat numbers as wildcards so
/// "Page 3 of 20" also removes "Page 4 of 20".
struct TextRemovalRule: Equatable {
    var text: String
    var ignoreCase = true
    var anyNumber = false
    var wholeLine = false

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func regex() -> NSRegularExpression? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }

        var pattern = words.map { word -> String in
            let escaped = NSRegularExpression.escapedPattern(for: word)
            return anyNumber
                ? escaped.replacingOccurrences(of: #"[0-9]+"#, with: #"\\d+"#, options: .regularExpression)
                : escaped
        }.joined(separator: #"\s+"#)

        var options: NSRegularExpression.Options = []
        if ignoreCase { options.insert(.caseInsensitive) }
        if wholeLine {
            // The whole line containing the text, including its line break.
            pattern = #"^[^\n]*"# + pattern + #"[^\n]*(?:\n|$)"#
            options.insert(.anchorsMatchLines)
        }
        return try? NSRegularExpression(pattern: pattern, options: options)
    }
}

enum TextRemover {

    static func count(in text: String, regex: NSRegularExpression) -> Int {
        regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// The first match with some text around it, for previews.
    static func firstMatchContext(in text: String, regex: NSRegularExpression, radius: Int = 40)
        -> (before: String, match: String, after: String)? {
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(m.range, in: text)
        else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let flat = { (s: Substring) in s.replacingOccurrences(of: "\n", with: " ") }
        return ((start > text.startIndex ? "…" : "") + flat(text[start..<range.lowerBound]),
                flat(text[range]),
                flat(text[range.upperBound..<end]) + (end < text.endIndex ? "…" : ""))
    }

    /// Removes every match, then tidies the spaces and blank lines left behind.
    static func remove(from text: String, regex: NSRegularExpression) -> String {
        let removed = regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        return tidy(removed)
    }

    static func tidy(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
                     .trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
