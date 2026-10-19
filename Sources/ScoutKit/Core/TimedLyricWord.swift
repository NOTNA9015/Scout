import Foundation

public struct TimedLyricWord: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }

    /// Keep the recognizer's real word times in portable Enhanced LRC.
    public static func enhancedLRC(_ input: [TimedLyricWord]) -> String {
        phrases(input).compactMap(lrcLine).joined(separator: "\n")
    }
    /// Heard words broken into lyric lines at pauses, sentence ends and natural lengths.
    public static func phrases(_ input: [TimedLyricWord]) -> [[TimedLyricWord]] {
        let words = input.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
            .map { TimedLyricWord(start: $0.start, end: $0.end, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var lines: [[TimedLyricWord]] = [], current: [TimedLyricWord] = []
        for word in words {
            if let last = current.last {
                let characters = current.reduce(0) { $0 + $1.text.count + 1 }
                let sentence = last.text.hasSuffix(".") || last.text.hasSuffix("?") || last.text.hasSuffix("!")
                let pause = word.start - last.end
                if pause > 0.65 || sentence || current.count >= 10 || characters >= 44 || (pause > 0.3 && (last.text.hasSuffix(",") || characters >= 26)) {
                    lines.append(current); current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
    /// Cleans recognizer output for sung audio: a run holding several words is split by
    /// letters, punctuation-only runs join the word before, times are made monotonic and
    /// non-overlapping, and a word's end is pulled in from silence after it.
    public static func refined(_ input: [TimedLyricWord]) -> [TimedLyricWord] {
        var words: [TimedLyricWord] = []
        for run in input.sorted(by: { $0.start < $1.start }) where run.start.isFinite && run.end.isFinite && run.start >= 0 {
            let parts = run.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let lettered = parts.filter { $0.contains { $0.isLetter || $0.isNumber } }
            if lettered.isEmpty {
                // Punctuation belongs to the word it follows.
                if !parts.isEmpty, var last = words.popLast() { last.text += parts.joined(); words.append(last) }
                continue
            }
            let end = max(run.start, run.end)
            if parts.count == 1 { words.append(.init(start: run.start, end: end, text: parts[0])); continue }
            let weights = parts.map { max(1, Double($0.filter { $0.isLetter || $0.isNumber }.count)) + 1 }
            let total = weights.reduce(0, +)
            var cursor = run.start
            for (part, weight) in zip(parts, weights) {
                let length = (end - run.start) * weight / total
                if part.contains(where: { $0.isLetter || $0.isNumber }) { words.append(.init(start: cursor, end: cursor + length, text: part)) }
                else if var last = words.popLast() { last.text += part; words.append(last) }
                cursor += length
            }
        }
        for index in words.indices {
            if index > 0 && words[index].start < words[index - 1].start { words[index].start = words[index - 1].start }
            let letters = Double(words[index].text.filter { $0.isLetter || $0.isNumber }.count)
            // Long enough for a held note, short enough that a gap after the word stays a gap.
            let longest = max(0.6, letters * 0.18 + 1.2)
            var end = min(words[index].end, words[index].start + longest)
            if index + 1 < words.count { end = min(end, words[index + 1].start) }
            words[index].end = max(words[index].start + 0.05, end)
            if index + 1 < words.count, words[index].end > words[index + 1].start { words[index].end = words[index + 1].start }
        }
        return words
    }
    /// Spread a line-timed lyric across its words so the karaoke sweep moves word by
    /// word. Weighted by letters (a rough syllable proxy) and capped so a line before
    /// a long instrumental break does not crawl until the next line starts.
    public static func estimated(_ text: String, start: Double, end: Double?) -> [TimedLyricWord] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty, start.isFinite, start >= 0 else { return [] }
        let weights = tokens.map { token in max(1, Double(token.filter(\.isLetter).count)) + 1.5 }
        let total = weights.reduce(0, +)
        let natural = 0.4 + total * 0.075
        let limit = end.map { $0 - start }.flatMap { $0.isFinite && $0 > 0.2 ? $0 : nil } ?? natural
        let span = min(limit, natural * 1.6)
        var cursor = start
        return zip(tokens, weights).map { token, weight in
            let length = span * weight / total
            defer { cursor += length }
            return .init(start: cursor, end: cursor + length, text: token)
        }
    }
    public static func parse(_ line: String, offset: Double = 0) -> [TimedLyricWord] {
        let pattern = try! NSRegularExpression(pattern: #"<(\d+):(\d{2})(?:[.:](\d{1,3}))?>"#)
        let tags = pattern.matches(in: line, range: NSRange(line.startIndex..., in: line))
        func time(_ match: NSTextCheckingResult) -> Double {
            func value(_ index: Int) -> String { Range(match.range(at: index), in: line).map { String(line[$0]) } ?? "" }
            let fraction = value(3)
            return max(0, (Double(value(1)) ?? 0) * 60 + (Double(value(2)) ?? 0) + (Double(fraction) ?? 0) / pow(10, Double(fraction.count)) + offset)
        }
        return tags.enumerated().compactMap { index, tag in
            guard index + 1 < tags.count, let begin = Range(tag.range, in: line)?.upperBound, let end = Range(tags[index+1].range, in: line)?.lowerBound else { return nil }
            let text = String(line[begin..<end]).trimmingCharacters(in: .whitespaces)
            let start = time(tag), finish = time(tags[index+1])
            guard !text.isEmpty, finish >= start else { return nil }
            return .init(start: start, end: finish, text: text)
        }
    }
}
