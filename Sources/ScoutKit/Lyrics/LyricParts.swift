import Foundation

/// Finding the lyrics for parts of a song that no lyric found by its name accounts for: a
/// mashup or medley of several songs, a leak that borrows a verse from another song, or a song
/// found under the wrong name. Lyrics services search by name, not by words sung, so Scout
/// searches for the songs a mashup's title names, more of the artists' songs, and songs named
/// after a phrase sung in those parts, and keeps only lyrics whose lines are really sung there.
public enum LyricParts {
    /// Passages worth a search: enough words to tell one song from another.
    public static func passages(_ assembly: LyricAssembly.Result) -> [[TimedLyricWord]] {
        assembly.unplaced.filter { words in
            guard words.count >= 6, let first = words.first, let last = words.last else { return false }
            return last.end - first.start >= 2
        }
    }

    /// The songs a title names as its parts: "A / B", "A x B", "A vs. B", "A + B", "Medley: A, B
    /// & C", "A (B Mashup)". An ordinary title gives none.
    public static func titleParts(_ title: String) -> [String] {
        var text = title.replacingOccurrences(of: #"\s*[\(\[](?:feat\.?|ft\.?|featuring|prod\.?|with)\s[^\)\]]*[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
        let kind = #"\b(?:mash-?up|medley|megamix|bootleg|blend)\b"#
        let medley = text.range(of: kind, options: [.regularExpression, .caseInsensitive]) != nil
        // What a bracket holds can be a part of its own: "Night Bus (Paper Boats Mashup)".
        var brackets: [String] = []
        if let regex = try? NSRegularExpression(pattern: #"[\(\[]([^\)\]]+)[\)\]]"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { brackets.append(String(text[range])) }
            }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        text = text.replacingOccurrences(of: #"^\s*(?:mash-?up|medley|megamix)\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        var separators = [#"\s+/\s*|\s*/\s+|(?<=\w)/(?=\w)"#, #"\s+\|\s+"#, #"\s+[x×]\s+"#, #"\s+vs\.?\s+"#, #"\s+\+\s+"#]
        // "&", commas and dashes are part of ordinary names; they separate songs only in a medley.
        if medley { separators += [#"\s+&\s+"#, #"\s*,\s*"#, #"\s+[-–—]\s+"#, #"\s+and\s+"#] }
        let pattern = separators.joined(separator: "|")
        func split(_ chunk: String) -> [String] {
            chunk.replacingOccurrences(of: pattern, with: "\u{1F}", options: [.regularExpression, .caseInsensitive]).components(separatedBy: "\u{1F}")
        }
        // A bracket names parts when it holds several, or calls itself a mashup.
        var named: [String] = []
        for chunk in brackets {
            let pieces = split(chunk)
            if pieces.count >= 2 || chunk.range(of: kind, options: [.regularExpression, .caseInsensitive]) != nil { named += pieces }
        }
        // The title's own name is a part when it holds several, or a bracket named another.
        let own = split(text)
        var parts: [String] = []
        for piece in (own.count >= 2 || !named.isEmpty ? own : []) + named {
            let name = piece.replacingOccurrences(of: kind + #"|\b(?:remix|edit|version|mix|live)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—:,&")))
            guard name.filter(\.isLetter).count >= 2, AlbumKey.normalize(name) != AlbumKey.normalize(title),
                  !parts.contains(where: { AlbumKey.normalize($0) == AlbumKey.normalize(name) }) else { continue }
            parts.append(name)
        }
        return Array(parts.prefix(5))
    }

    private static let common: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "i", "im", "ive", "ill", "id", "me", "my", "you", "your", "youre", "we", "us", "our",
        "he", "she", "it", "its", "they", "them", "his", "her", "to", "of", "in", "on", "at", "for", "with", "is", "are", "was", "were",
        "be", "been", "am", "do", "dont", "did", "that", "this", "what", "when", "if", "no", "not", "just", "like", "got", "get", "can",
        "oh", "ooh", "ah", "uh", "um", "yeah", "yea", "hey", "la", "na", "da", "mm", "huh", "woah", "whoa",
    ]
    /// Phrases a song is likely named after, from the passages to look for: phrases sung more
    /// than once (a hook) first, then the opening words of long passages.
    public static func phrases(_ passages: [[TimedLyricWord]], heard: [TimedLyricWord], limit: Int = 6) -> [String] {
        let all = heard.map { LyricAlignment.key($0.text) }.filter { !$0.isEmpty }
        var counts: [String: Int] = [:]
        for n in 2...4 where all.count >= n { for i in 0...(all.count - n) { counts[all[i..<(i + n)].joined(separator: " "), default: 0] += 1 } }
        func meaningful(_ words: ArraySlice<String>) -> Bool { words.contains { $0.count >= 3 && !common.contains($0) } }
        var hooks: [(phrase: String, score: Int)] = [], openings: [String] = []
        for passage in passages {
            let words = passage.map { LyricAlignment.key($0.text) }.filter { !$0.isEmpty }
            var best: (phrase: String, score: Int)?
            for n in 2...4 where words.count >= n {
                for i in 0...(words.count - n) where meaningful(words[i..<(i + n)]) {
                    let phrase = words[i..<(i + n)].joined(separator: " "), count = counts[phrase] ?? 0
                    if count >= 2, count * n > best?.score ?? 0 { best = (phrase, count * n) }
                }
            }
            if let best { hooks.append(best) }
            if words.count >= 8, let start = words.indices.first(where: { meaningful(words[$0...$0]) }) {
                openings.append(words[start..<min(words.count, start + 3)].joined(separator: " "))
            }
        }
        var result: [String] = []
        for phrase in hooks.sorted(by: { $0.score > $1.score }).map(\.phrase) + openings
        where !result.contains(where: { $0.contains(phrase) || phrase.contains($0) }) { result.append(phrase) }
        return Array(result.prefix(limit))
    }

    /// The lyrics among `candidates` whose lines are really sung in these passages, the one
    /// accounting for most first; one that adds nothing to those before it is left out.
    public static func vet(_ candidates: [LyricCandidate], passages: [[TimedLyricWord]], limit: Int = 4) -> [LyricCandidate] {
        let words = passages.flatMap { $0 }
        guard !words.isEmpty else { return [] }
        // A quick look first: pairs of words this lyric shares with what was heard.
        func plain(_ word: String) -> String { let key = LyricAlignment.key(word); return LyricAlignment.spoken[key] ?? key }
        let heardWords = words.map { plain($0.text) }
        let heardPairs = Set(zip(heardWords, heardWords.dropFirst()).map { $0 + " " + $1 })
        var seen = Set<String>()
        let likely = candidates.filter { seen.insert($0.id).inserted }.map { candidate -> (LyricCandidate, Int) in
            let lyric = candidate.lines.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map { plain(String($0)) } }.filter { !$0.isEmpty }
            return (candidate, Set(zip(lyric, lyric.dropFirst()).map { $0 + " " + $1 }).intersection(heardPairs).count)
        }.filter { $0.1 >= 2 }.sorted { $0.1 > $1.1 }.prefix(12)
        // Then the lyric pieced against the passages alone.
        var found: [(candidate: LyricCandidate, covered: Set<Double>)] = []
        for (candidate, _) in likely {
            let result = LyricAssembly.assemble(heard: words, pieces: [candidate])
            let placed = result.lines.filter { $0.origin != .heard }
            let left = Set(result.unplaced.flatMap { $0 }.map(\.start))
            let covered = Set(words.map(\.start)).subtracting(left)
            guard placed.count >= 2, covered.count >= 8 else { continue }
            found.append((candidate, covered))
        }
        var result: [LyricCandidate] = [], taken = Set<Double>()
        for item in found.sorted(by: { $0.covered.count > $1.covered.count }) where result.count < limit {
            guard item.covered.subtracting(taken).count >= 6 else { continue }
            result.append(item.candidate); taken.formUnion(item.covered)
        }
        return result
    }
}
