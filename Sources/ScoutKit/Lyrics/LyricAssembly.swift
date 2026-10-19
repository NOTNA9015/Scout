import Foundation

/// Pieces a song's lyrics together from what was heard in the audio and lines of lyrics found
/// online. The audio decides the order and the length: a verse that moved, a chorus sung more
/// often, a part cut or added, or a version longer or shorter than any lyric online all come
/// out as sung. Each stretch of the audio takes the written line it matches, keeping its
/// spelling and taking the recognized word times; lines the recognizer missed between two
/// placed lines are filled in from the lyric they came from; what no line matches stays as heard.
public enum LyricAssembly {
    public enum Origin: Equatable, Sendable {
        /// A written line found in the audio (the id of the lyric it came from).
        case online(String)
        /// A written line the recognizer missed or misheard, placed by its neighbours in that lyric.
        case filled(String)
        /// Words as heard, where no written line matched.
        case heard
    }
    public struct Line: Equatable, Sendable {
        public var words: [TimedLyricWord]
        public var origin: Origin
        public var text: String { words.map(\.text).joined(separator: " ") }
    }
    public struct Result: Equatable, Sendable {
        public var lines: [Line]
        /// Share of the heard words that written lines account for.
        public var onlineShare: Double
        /// Share of the heard words in whole passages no written line matched: parts this
        /// version has that the lyrics found don't.
        public var addedShare: Double
        /// The ids of the lyrics whose lines were used, most used first.
        public var sources: [String]
        /// The written lines used (`signature`s).
        public var used: Set<String>
        public var onlineLines: Int { lines.filter { $0.origin != .heard }.count }
        public var heardLines: Int { lines.count - onlineLines }
        public var lrc: String { lines.compactMap { TimedLyricWord.lrcLine($0.words) }.joined(separator: "\n") }
        public static let empty = Result(lines: [], onlineShare: 0, addedShare: 0, sources: [], used: [])
    }

    /// One distinct written line, and everywhere it appears in the lyrics given.
    private struct Written {
        var text: String
        var words: [String]
        var places: [(piece: Int, line: Int)]
    }
    /// One place in the audio a written line was sung.
    private struct Hit {
        var line: Int, first: Int, last: Int, matched: Int, weight: Double
    }

    public static func assemble(heard input: [TimedLyricWord], pieces: [LyricCandidate]) -> Result {
        let heard = input.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && !LyricAlignment.key($0.text).isEmpty }
            .sorted { $0.start < $1.start }
        guard !heard.isEmpty else { return .empty }
        let m = heard.count

        // Every distinct written line (the same line in several lyrics, or sung twice, is one).
        var written: [Written] = [], index: [String: Int] = [:], order: [[Int]] = []
        for (p, piece) in pieces.enumerated() {
            var ids: [Int] = []
            for line in piece.lines {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                guard !isLabel(text) else { continue }
                let words = text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !LyricAlignment.key($0).isEmpty }
                guard !words.isEmpty else { continue }
                let sig = signature(text)
                let id: Int
                if let known = index[sig] { id = known } else {
                    id = written.count; index[sig] = id
                    written.append(.init(text: text, words: words, places: []))
                }
                written[id].places.append((p, ids.count)); ids.append(id)
            }
            order.append(ids)
        }

        // Every place each line was sung.
        var scorer = LyricAlignment.Scorer(heard: heard.map(\.text))
        var hits: [Hit] = []
        for (id, line) in written.enumerated() {
            let rows = line.words.map { scorer.row($0) }
            hits += find(id, rows: rows, scorer: scorer, heard: heard)
        }
        // Lyrics of another song match a line here and there; keep lyrics whose lines are
        // really found in this audio.
        var found: [Int: Int] = [:]                            // line → most of its words heard at once
        for hit in hits { found[hit.line] = max(found[hit.line] ?? 0, hit.matched) }
        let relevant = order.map { ids -> Bool in
            let unique = Set(ids).filter { found[$0] != nil }, share = Double(unique.count) / Double(max(1, Set(ids).count))
            let words = unique.reduce(0) { $0 + found[$1]! }
            return unique.count >= 6 || unique.count >= 3 && share >= 0.2 || unique.count >= 1 && share >= 0.5
                || unique.count >= 2 && words >= 8 && Double(words) >= Double(m) * 0.3
        }
        hits = hits.filter { hit in written[hit.line].places.contains { relevant[$0.piece] } }

        // The best set of lines that don't overlap, favouring lines that follow each other in a lyric.
        var before = [Set<Int>](repeating: [], count: written.count)
        for (p, ids) in order.enumerated() where relevant[p] { for (a, b) in zip(ids, ids.dropFirst()) { before[b].insert(a) } }
        hits.sort { $0.last == $1.last ? $0.first < $1.first : $0.last < $1.last }
        var best = [Double](repeating: 0, count: hits.count), parent = [Int](repeating: -1, count: hits.count)
        var prefix: [(score: Double, hit: Int)] = []           // the best chain ending at or before each hit
        var byLine: [Int: [Int]] = [:]
        for k in hits.indices {
            let hit = hits[k]
            // Chains ending before this hit starts: the hits are sorted by where they end.
            var low = 0, high = k
            while low < high { let mid = (low + high) / 2; if hits[mid].last < hit.first { low = mid + 1 } else { high = mid } }
            var score = 0.0, from = -1
            if low > 0, prefix[low - 1].score > 0 { score = prefix[low - 1].score; from = prefix[low - 1].hit }
            for line in before[hit.line] {
                for e in byLine[line] ?? [] where hits[e].last < hit.first && heard[hit.first].start - heard[hits[e].last].end < 20 {
                    let chained = best[e] + 1.5
                    if chained > score { score = chained; from = e }
                }
            }
            best[k] = hit.weight + score; parent[k] = from
            prefix.append(k > 0 && prefix[k - 1].score >= best[k] ? prefix[k - 1] : (best[k], k))
            byLine[hit.line, default: []].append(k)
        }
        var chosen: [Hit] = []
        var cursor = prefix.last?.hit ?? -1
        while cursor >= 0 { chosen.append(hits[cursor]); cursor = parent[cursor] }
        chosen.reverse()

        // Lines from the lyrics, timed by the words heard where each was sung.
        var lines: [Line] = [], used = Set<String>()
        var covered = [Bool](repeating: false, count: m)
        func origin(_ line: Int) -> String { pieces[written[line].places.first { relevant[$0.piece] }?.piece ?? 0].id }
        var previousEnd = 0.0
        func add(_ filled: (lines: [Line], texts: [String], words: Range<Int>)) {
            lines += filled.lines; used.formUnion(filled.texts.map(signature))
            for j in filled.words { covered[j] = true }
            previousEnd = max(previousEnd, filled.lines.last?.words.last?.end ?? previousEnd)
        }
        if let first = chosen.first, let filled = edge(first, leading: true, written: written, order: order, relevant: relevant, heard: heard, pieces: pieces) { add(filled) }
        for (offset, hit) in chosen.enumerated() {
            let words = LyricAlignment.align([.init(time: nil, text: written[hit.line].text)], recognized: Array(heard[hit.first...hit.last]), after: previousEnd).lines[0]
            lines.append(.init(words: words, origin: .online(origin(hit.line)))); used.insert(signature(written[hit.line].text))
            for j in hit.first...hit.last { covered[j] = true }
            previousEnd = words.last?.end ?? previousEnd
            if offset + 1 < chosen.count {
                if let filled = between(hit, chosen[offset + 1], written: written, order: order, relevant: relevant, heard: heard, pieces: pieces) { add(filled) }
            } else if let filled = edge(hit, leading: false, written: written, order: order, relevant: relevant, heard: heard, pieces: pieces) { add(filled) }
        }
        let onlineWords = covered.filter { $0 }.count
        let firstCovered = covered.firstIndex(of: true) ?? m, lastCovered = covered.lastIndex(of: true) ?? -1
        var added = 0

        // What no written line matched stays as heard. A word or two right against a placed
        // line is most likely part of it, misheard.
        var j = 0
        while j < m {
            guard !covered[j] else { j += 1; continue }
            var stop = j
            while stop < m && !covered[stop] { stop += 1 }
            let run = Array(heard[j..<stop])
            let touchesBefore = j > 0 && covered[j - 1] && heard[j].start - heard[j - 1].end < 1
            let touchesAfter = stop < m && covered[stop] && heard[stop].start - heard[stop - 1].end < 1
            if run.count > 2 || !(touchesBefore || touchesAfter) {
                lines += TimedLyricWord.phrases(run).map { Line(words: $0, origin: .heard) }
            }
            // A passage inside the song, or a long one at either end, that no lyric has.
            if run.count >= 8 || run.count >= 4 && j > firstCovered && stop <= lastCovered { added += run.count }
            j = stop
        }

        lines.sort { ($0.words.first?.start ?? 0) < ($1.words.first?.start ?? 0) }
        lines = monotonic(lines)
        var uses: [String: Int] = [:]
        for line in lines { switch line.origin { case .online(let id), .filled(let id): uses[id, default: 0] += 1; case .heard: break } }
        let sources = pieces.map(\.id).filter { uses[$0] != nil }.sorted { uses[$0]! > uses[$1]! }
        return Result(lines: lines, onlineShare: Double(onlineWords) / Double(m), addedShare: Double(added) / Double(m), sources: sources, used: used)
    }

    /// A written line as compared: its words' letters, or "" for a section name or a line without words.
    public static func signature(_ text: String) -> String {
        guard !isLabel(text.trimmingCharacters(in: .whitespaces)) else { return "" }
        return text.split(whereSeparator: \.isWhitespace).map { LyricAlignment.key(String($0)) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// Section names some lyrics carry as lines ("Chorus:", "(Verse 2)").
    static func isLabel(_ text: String) -> Bool {
        let name = "(?:intro|outro|verse|chorus|pre-?chorus|post-?chorus|hook|bridge|refrain|interlude|instrumental)"
        // "[Verse 2: Ye]", "(Chorus)"; "Chorus x2", "Verse 1"; "Bridge (Juno):".
        return [#"^[\[(]\s*"# + name + #"\b[^\])]*[\])]$"#, "^" + name + #"(?:\s*\d+)?(?:\s*[x×]\s*\d+)?\s*:?$"#, "^" + name + #"\b[^:]{0,40}:$"#]
            .contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Where one written line was sung: the whole line fitted against any stretch of the
    /// transcript, keeping each stretch that fits well and tightly.
    private static func find(_ line: Int, rows: [Int], scorer: LyricAlignment.Scorer, heard: [TimedLyricWord]) -> [Hit] {
        let n = rows.count, m = heard.count, width = m + 1
        var score = [Int](repeating: 0, count: (n + 1) * width), move = [UInt8](repeating: 0, count: (n + 1) * width)
        for i in 1...n { score[i * width] = -i; move[i * width] = 1 }
        for i in 1...n {
            for j in 1...m {
                let pair = scorer.score(rows[i - 1], j - 1)
                let diagonal = score[(i - 1) * width + j - 1] + (pair > 0 ? pair : -1)
                let up = score[(i - 1) * width + j] - 1, left = score[i * width + j - 1] - 1
                if diagonal >= up && diagonal >= left { score[i * width + j] = diagonal; move[i * width + j] = pair > 0 ? 3 : 0 }
                else if up >= left { score[i * width + j] = up; move[i * width + j] = 1 }
                else { score[i * width + j] = left; move[i * width + j] = 2 }
            }
        }
        let required = n >= 3 ? max(2, Int((Double(n) * 0.5).rounded(.up))) : n
        var hits: [Hit] = [], seen = Set<Int>()
        let last = n * width
        for end in 1...m {
            let value = score[last + end]
            guard value > 0, value >= score[last + end - 1], end == m || value > score[last + end + 1] else { continue }
            var i = n, j = end, matched = 0, exact = 0, total = 0, first = -1, final = -1
            while i > 0 && j > 0 {
                switch move[i * width + j] {
                case 3:
                    let pair = scorer.score(rows[i - 1], j - 1)
                    matched += 1; total += pair; if pair == 3 { exact += 1 }
                    if final < 0 { final = j - 1 }; first = j - 1
                    i -= 1; j -= 1
                case 0: i -= 1; j -= 1
                case 1: i -= 1
                default: j -= 1
                }
            }
            guard matched >= required, first >= 0, seen.insert(first * (m + 1) + final).inserted else { continue }
            // Short lines must be heard exactly; any line must be sung as one tight phrase.
            if n <= 2 && exact < n { continue }
            let span = final - first + 1
            guard Double(matched) >= Double(span) * 0.5, heard[final].end - heard[first].start <= Double(n) * 1.6 + 4 else { continue }
            let weight = Double(total) - 0.5 * Double(n - matched) - 0.5 * Double(span - matched)
            if weight > 0 { hits.append(.init(line: line, first: first, last: final, matched: matched, weight: weight)) }
        }
        return hits
    }

    /// The lines a lyric has between two placed lines, when the recognizer missed them but the
    /// audio between has room for them (or heard words that fit them).
    private static func between(_ a: Hit, _ b: Hit, written: [Written], order: [[Int]], relevant: [Bool],
                                heard: [TimedLyricWord], pieces: [LyricCandidate]) -> (lines: [Line], texts: [String], words: Range<Int>)? {
        for place in written[a.line].places where relevant[place.piece] {
            let ids = order[place.piece]
            let after = place.line
            let upper = min(after + 4, ids.count - 1)
            guard after + 2 <= upper, let target = (after + 2...upper).first(where: { ids[$0] == b.line }) else { continue }
            let missing = ids[(after + 1)..<target].map { written[$0] }
            let count = missing.reduce(0) { $0 + $1.words.count }
            let begin = heard[a.last].end, end = heard[b.first].start, room = end - begin
            let gap = a.last + 1 < b.first ? Array(heard[(a.last + 1)..<b.first]) : []
            let lines = missing.map { LyricAlignment.Line(time: nil, text: $0.text) }
            let id = pieces[place.piece].id, texts = missing.map(\.text), words = (a.last + 1)..<b.first
            // Room to sing them besides the usual pause between lines, and not so much that
            // the song clearly went somewhere else.
            let fits = room >= Double(count) * 0.3 + 1.5 && room <= Double(count) * 1.0 + 6
            if gap.isEmpty {
                guard fits else { continue }
                return (spread(texts, from: begin + 0.05, to: end - 0.05).map { Line(words: $0, origin: .filled(id)) }, texts, words)
            }
            let aligned = LyricAlignment.align(lines, recognized: gap, after: begin)
            let plausible = gap.count <= count * 2 && gap.count * 3 >= count && room <= Double(count) * 1.0 + 6
            guard aligned.matched >= 0.25 || plausible else { continue }
            let filled = aligned.lines.map { words in
                Line(words: words.map { .init(start: min(max($0.start, begin), end), end: min(max($0.end, begin), end), text: $0.text) }, origin: .filled(id))
            }
            return (filled, texts, words)
        }
        return nil
    }

    /// Up to three lines of a lyric just before the first placed line (or just after the last)
    /// that the recognizer heard too poorly to place alone, kept when the words heard right
    /// there fit them.
    private static func edge(_ hit: Hit, leading: Bool, written: [Written], order: [[Int]], relevant: [Bool],
                             heard: [TimedLyricWord], pieces: [LyricCandidate]) -> (lines: [Line], texts: [String], words: Range<Int>)? {
        let available = leading ? 0..<hit.first : (hit.last + 1)..<heard.count
        guard !available.isEmpty else { return nil }
        for place in written[hit.line].places where relevant[place.piece] {
            let ids = order[place.piece]
            for k in stride(from: 3, through: 1, by: -1) {
                let range = leading ? (place.line - k)..<place.line : (place.line + 1)..<(place.line + 1 + k)
                guard range.lowerBound >= 0, range.upperBound <= ids.count else { continue }
                let texts = range.map { written[ids[$0]].text }
                let count = range.reduce(0) { $0 + written[ids[$1]].words.count }
                let window = leading ? max(available.lowerBound, available.upperBound - count * 2)..<available.upperBound
                                     : available.lowerBound..<min(available.upperBound, available.lowerBound + count * 2)
                let gap = Array(heard[window])
                // Sung right against the placed line.
                let distance = leading ? heard[hit.first].start - gap[gap.count - 1].end : gap[0].start - heard[hit.last].end
                guard distance <= 3 else { continue }
                let floor = leading ? max(0, gap[0].start - 0.5) : heard[hit.last].end
                let aligned = LyricAlignment.align(texts.map { .init(time: nil, text: $0) }, recognized: gap, after: floor)
                guard aligned.matched >= 0.4, let first = aligned.lines.first?.first, let last = aligned.lines.last?.last else { continue }
                // The heard words these lines took; earlier (or later) ones stay as heard.
                let taken = window.filter { leading ? heard[$0].start >= first.start - 0.01 : heard[$0].end <= last.end + 0.01 }
                guard let low = taken.first, let high = taken.last else { continue }
                let id = pieces[place.piece].id
                return (aligned.lines.map { Line(words: $0, origin: .filled(id)) }, texts, low..<(high + 1))
            }
        }
        return nil
    }

    /// Lines spread over a stretch with nothing heard, weighted by their letters.
    private static func spread(_ texts: [String], from begin: Double, to end: Double) -> [[TimedLyricWord]] {
        let weights = texts.map { Double($0.filter(\.isLetter).count) + 4 }
        let total = weights.reduce(0, +)
        var cursor = begin
        return zip(texts, weights).map { text, weight in
            let length = max(0.2, (end - begin) * weight / total)
            defer { cursor += length }
            return TimedLyricWord.estimated(text, start: cursor, end: cursor + length)
        }
    }

    /// Every word starts no earlier than the one before it and ends by the time the next begins.
    private static func monotonic(_ lines: [Line]) -> [Line] {
        var result = lines.filter { !$0.words.isEmpty }
        var previous = 0.0
        for l in result.indices { for w in result[l].words.indices {
            result[l].words[w].start = max(result[l].words[w].start, previous); previous = result[l].words[w].start
        } }
        var following = Double.infinity
        for l in result.indices.reversed() { for w in result[l].words.indices.reversed() {
            result[l].words[w].end = max(result[l].words[w].start, min(result[l].words[w].end, following))
            following = result[l].words[w].start
        } }
        return result
    }
}
