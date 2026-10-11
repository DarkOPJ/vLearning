import Foundation
import NaturalLanguage

/// Turns page text into sentences the TTS engine can read one at a time.
///
/// Document text often has no full stops (titles, bullets, OCR lines), so lines are first grouped
/// into units: a line that ends without punctuation ends its unit, unless the next line clearly
/// continues it (starts lowercase). Units are then split with NLTokenizer, and every sentence
/// gets terminal punctuation so the voice ends it naturally.
enum SentenceSplitter {

    /// Sentences longer than this are split at a comma or semicolon near the middle.
    static let maxSentenceLength = 320

    static func split(_ text: String) -> [String] {
        units(from: text)
            .flatMap(tokenize)
            .flatMap(splitLong)
            .map(finish)
            .filter { $0.rangeOfCharacter(from: .alphanumerics) != nil }
    }

    // MARK: - Lines → units

    private static let terminal: Set<Character> = [".", "!", "?", ":", ";", "…", "\"", "”", "'", "’", ")"]

    static func units(from text: String) -> [String] {
        var units: [String] = []
        var current = ""

        func flush() {
            let unit = current.trimmingCharacters(in: .whitespaces)
            if !unit.isEmpty { units.append(unit) }
            current = ""
        }

        let lines = text.components(separatedBy: .newlines).map(stripListMarker)
        for (i, line) in lines.enumerated() {
            guard !line.isEmpty else { flush(); continue }  // blank line = paragraph break

            if current.hasSuffix("-"), line.first?.isLowercase == true {
                current.removeLast()  // word hyphenated across a line break
                current += line
            } else {
                current += current.isEmpty ? line : " " + line
            }

            let next = lines.dropFirst(i + 1).first ?? ""
            let continues = next.first?.isLowercase == true || current.hasSuffix("-")
            if let last = current.last, !terminal.contains(last), !continues {
                flush()  // heading, bullet, or line that simply has no full stop
            }
        }
        flush()
        return units
    }

    /// Removes bullets and list numbering ("•", "-", "1.", "a)") from the start of a line.
    static func stripListMarker(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = #"^([-•*▪●◦‣–—]|\d{1,3}[.)]|[a-zA-Z][)])\s+"#
        guard let range = trimmed.range(of: pattern, options: .regularExpression) else { return trimmed }
        return String(trimmed[range.upperBound...])
    }

    // MARK: - Units → sentences

    private static func tokenize(_ unit: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = unit
        tokenizer.setLanguage(.english)
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: unit.startIndex..<unit.endIndex) { range, _ in
            let sentence = unit[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences.isEmpty ? [unit] : sentences
    }

    private static func splitLong(_ sentence: String) -> [String] {
        guard sentence.count > maxSentenceLength else { return [sentence] }
        let middle = sentence.index(sentence.startIndex, offsetBy: sentence.count / 2)
        let breaks = sentence.indices.filter { [";", ","].contains(sentence[$0]) }
        guard let best = breaks.min(by: {
            abs(sentence.distance(from: middle, to: $0)) < abs(sentence.distance(from: middle, to: $1))
        }) else { return [sentence] }
        let head = String(sentence[...best]).trimmingCharacters(in: .whitespaces)
        let tail = String(sentence[sentence.index(after: best)...]).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, !tail.isEmpty else { return [sentence] }
        return splitLong(head) + splitLong(tail)
    }

    /// Ends the sentence with a full stop if it has no terminal punctuation.
    private static func finish(_ sentence: String) -> String {
        var s = sentence.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix(",") || s.hasSuffix(";") || s.hasSuffix(":") { s.removeLast() }
        if let last = s.last, ![".", "!", "?", "…"].contains(last) {
            let closers: Set<Character> = ["\"", "”", "'", "’", ")"]
            if closers.contains(last), s.dropLast().last.map({ [".", "!", "?"].contains($0) }) == true {
                return s
            }
            s += "."
        }
        return s
    }

    // MARK: - Tables

    /// Reads tab-separated rows as sentences: with a header row, "Name: Ada, Score: 95."
    static func tableSentences(_ table: String) -> [String] {
        let rows = table.components(separatedBy: .newlines)
            .map { $0.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { $0.contains { !$0.isEmpty } }
        guard !rows.isEmpty else { return [] }

        let header = rows[0]
        let hasHeader = rows.count >= 2 && header.count >= 2 && header.allSatisfy { !$0.isEmpty }
        let body = hasHeader ? Array(rows.dropFirst()) : rows

        return body.map { cells in
            let parts: [String] = hasHeader
                ? zip(header, cells).compactMap { $1.isEmpty ? nil : "\($0): \($1)" }
                : cells.filter { !$0.isEmpty }
            return finish(parts.joined(separator: ", "))
        }
    }
}
