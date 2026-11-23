import Foundation

/// Pieces a song's lyrics together from what was heard in the audio and lyrics found online.
/// The audio decides the order and the length: a verse that moved, a chorus sung more often, a
/// part cut or added, a version longer or shorter than any lyric online, or a song made of parts
/// of several songs all come out as sung. Each stretch of the audio takes the written line it
/// matches, keeping its spelling and taking the recognized word times. Lines the recognizer
/// missed are filled in from the lyric they came from, at that lyric's own timing moved to fit
/// this version. What no line matches stays as heard, and only once: heard words that a placed
/// line already shows are not shown again.
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
        /// The stretches of the audio left as heard, in order: what a search by parts looks for.
        public var unplaced: [[TimedLyricWord]]
        public var onlineLines: Int { lines.filter { $0.origin != .heard }.count }
        public var heardLines: Int { lines.count - onlineLines }
        public var lrc: String { lines.compactMap { TimedLyricWord.lrcLine($0.words) }.joined(separator: "\n") }
        public static let empty = Result(lines: [], onlineShare: 0, addedShare: 0, sources: [], used: [], unplaced: [])
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
    /// Lines filled in, their texts, and the heard words they account for.
    private typealias Filled = (lines: [Line], texts: [String], words: Range<Int>)
    /// What every step works from.
    private struct Context {
        let heard: [TimedLyricWord]
        let pieces: [LyricCandidate]
        let written: [Written]
        /// Per lyric, its lines in order, as `written` ids.
        let order: [[Int]]
        /// Per lyric, when each of its lines starts in that lyric (between two timed lines, spread
        /// evenly); nil for a lyric without times.
        let times: [[Double]?]
        let relevant: [Bool]
    }

    /// `trusted`: ids of lyrics already checked against this audio (parts of it found by a
    /// search), used wherever their lines are found, however small a share of the song they are.
    public static func assemble(heard input: [TimedLyricWord], pieces: [LyricCandidate], trusted: Set<String> = []) -> Result {
        let heard = input.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && !LyricAlignment.key($0.text).isEmpty }
            .sorted { $0.start < $1.start }
        guard !heard.isEmpty else { return .empty }
        let m = heard.count

        // Every distinct written line (the same line in several lyrics, or sung twice, is one),
        // with overlong lines cut to the length they are sung in.
        var written: [Written] = [], index: [String: Int] = [:], order: [[Int]] = [], times: [[Double]?] = []
        for (p, piece) in pieces.enumerated() {
            var ids: [Int] = [], stamps: [Double?] = []
            for line in piece.lines {
                for (k, text) in sungLines(line.text).enumerated() {
                    let words = text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !LyricAlignment.key($0).isEmpty }
                    let sig = signature(text)
                    guard !words.isEmpty, !sig.isEmpty else { continue }
                    let id: Int
                    if let known = index[sig] { id = known } else {
                        id = written.count; index[sig] = id
                        written.append(.init(text: text, words: words, places: []))
                    }
                    written[id].places.append((p, ids.count)); ids.append(id)
                    stamps.append(k == 0 ? line.time : nil)
                }
            }
            order.append(ids); times.append(interpolated(stamps))
        }

        // Every place each line was sung.
        var scorer = LyricAlignment.Scorer(heard: heard.map(\.text))
        var rows: [[Int]] = []
        var hits: [Hit] = []
        for (id, line) in written.enumerated() {
            rows.append(line.words.map { scorer.row($0) })
            hits += find(id, rows: rows[id], scorer: scorer, heard: heard, within: 0..<m)
        }
        // Lyrics of another song match a line here and there; keep lyrics whose lines are
        // really found in this audio.
        var found: [Int: Int] = [:], byLine: [Int: [Hit]] = [:]          // line → most of its words heard at once
        for hit in hits { found[hit.line] = max(found[hit.line] ?? 0, hit.matched); byLine[hit.line, default: []].append(hit) }
        let relevant = order.enumerated().map { p, ids -> Bool in
            if trusted.contains(pieces[p].id) { return true }
            let unique = Set(ids).filter { found[$0] != nil }, share = Double(unique.count) / Double(max(1, Set(ids).count))
            let words = unique.reduce(0) { $0 + found[$1]! }
            if unique.count >= 6 || unique.count >= 3 && share >= 0.2 || unique.count >= 1 && share >= 0.5
                || unique.count >= 2 && words >= 8 && Double(words) >= Double(m) * 0.3 { return true }
            // Several of its lines sung one after another, in its order: a part of this lyric,
            // however small a share of the song (a verse borrowed from another song).
            let run = longestRun(ids, hits: byLine, heard: heard)
            return run.lines >= 3 || run.lines >= 2 && run.words >= 10
        }
        hits = hits.filter { hit in written[hit.line].places.contains { relevant[$0.piece] } }
        let context = Context(heard: heard, pieces: pieces, written: written, order: order, times: times, relevant: relevant)

        // The best set of lines that don't overlap, favouring lines that follow each other in a lyric.
        var before = [Set<Int>](repeating: [], count: written.count)
        for (p, ids) in order.enumerated() where relevant[p] { for (a, b) in zip(ids, ids.dropFirst()) { before[b].insert(a) } }
        hits.sort { $0.last == $1.last ? $0.first < $1.first : $0.last < $1.last }
        var best = [Double](repeating: 0, count: hits.count), parent = [Int](repeating: -1, count: hits.count)
        var prefix: [(score: Double, hit: Int)] = []           // the best chain ending at or before each hit
        var chained: [Int: [Int]] = [:]
        for k in hits.indices {
            let hit = hits[k]
            // Chains ending before this hit starts: the hits are sorted by where they end.
            var low = 0, high = k
            while low < high { let mid = (low + high) / 2; if hits[mid].last < hit.first { low = mid + 1 } else { high = mid } }
            var score = 0.0, from = -1
            if low > 0, prefix[low - 1].score > 0 { score = prefix[low - 1].score; from = prefix[low - 1].hit }
            for line in before[hit.line] {
                for e in chained[line] ?? [] where hits[e].last < hit.first && heard[hit.first].start - heard[hits[e].last].end < 20 {
                    let total = best[e] + 1.5
                    if total > score { score = total; from = e }
                }
            }
            best[k] = hit.weight + score; parent[k] = from
            prefix.append(k > 0 && prefix[k - 1].score >= best[k] ? prefix[k - 1] : (best[k], k))
            chained[hit.line, default: []].append(k)
        }
        var chain: [Hit] = []
        var cursor = prefix.last?.hit ?? -1
        while cursor >= 0 { chain.append(hits[cursor]); cursor = parent[cursor] }
        chain.reverse()
        // A line placed twice in a row where no lyric repeats it is one line heard twice over (an
        // echo, a doubled vocal): the fuller of the two stays, and takes the other's words.
        var twice = Set<Int>()
        for (p, ids) in order.enumerated() where relevant[p] { for (a, b) in zip(ids, ids.dropFirst()) where a == b { twice.insert(a) } }
        var chosen: [Hit] = [], echoes: [ClosedRange<Int>] = []
        for hit in chain {
            if let last = chosen.last, last.line == hit.line, !twice.contains(hit.line), hit.first - last.last <= 2,
               heard[hit.first].start - heard[last.last].end < 2, min(last.matched, hit.matched) < written[hit.line].words.count {
                if hit.matched > last.matched { echoes.append(last.first...last.last); chosen[chosen.count - 1] = hit } else { echoes.append(hit.first...hit.last) }
                continue
            }
            chosen.append(hit)
        }

        // Lines from the lyrics, timed by the words heard where each was sung.
        var lines: [Line] = [], used = Set<String>()
        var covered = [Bool](repeating: false, count: m)
        func origin(_ line: Int) -> String { pieces[written[line].places.first { relevant[$0.piece] }?.piece ?? 0].id }
        func add(_ filled: Filled) {
            lines += filled.lines; used.formUnion(filled.texts.map(signature))
            for j in filled.words { covered[j] = true }
        }
        func place(_ hit: Hit) {
            // No word before the end of the heard word just before this line.
            let floor = hit.first > 0 ? heard[hit.first - 1].end : 0
            let words = LyricAlignment.align([.init(time: nil, text: written[hit.line].text)], recognized: Array(heard[hit.first...hit.last]), after: floor).lines[0]
            lines.append(.init(words: words, origin: .online(origin(hit.line)))); used.insert(signature(written[hit.line].text))
            for j in hit.first...hit.last { covered[j] = true }
        }
        if let first = chosen.first, let filled = edge(first, leading: true, context) { add(filled) }
        for (offset, hit) in chosen.enumerated() {
            place(hit)
            if offset + 1 < chosen.count {
                if let filled = between(hit, chosen[offset + 1], context) { add(filled) }
            } else if let filled = edge(hit, leading: false, context) { add(filled) }
        }
        for echo in echoes { for j in echo { covered[j] = true } }

        // A second look at what is left: a line the best chain passed over because it overlapped
        // another (a chorus sung once more, a line run into the next one). Not a line already
        // shown right there: that is the line heard twice over, dealt with below.
        let lyricLines = written.indices.filter { written[$0].places.contains { relevant[$0.piece] } }
        for run in runs(covered) where run.count >= 3 {
            var extra: [Hit] = []
            for id in lyricLines { extra += find(id, rows: rows[id], scorer: scorer, heard: heard, within: run) }
            for hit in extra.sorted(by: { $0.weight > $1.weight }) where !(hit.first...hit.last).contains(where: { covered[$0] }) {
                let text = signature(written[hit.line].text), start = heard[hit.first].start, end = heard[hit.last].end
                let nearby = lines.contains { line in
                    signature(line.text) == text && (line.words.first?.start ?? 0) - end < 4 && start - (line.words.last?.end ?? 0) < 4
                }
                if !nearby || twice.contains(hit.line) { place(hit) }
            }
        }

        // Words heard twice over: what a placed line already shows (its own words heard apart
        // from it, an echo of it) is not shown again as heard.
        let placed = lines.filter { !$0.words.isEmpty }
        for run in runs(covered) {
            let words = Array(heard[run])
            if placed.contains(where: { repeats(words, $0) }) { for j in run { covered[j] = true } }
        }
        let onlineWords = covered.filter { $0 }.count
        let firstCovered = covered.firstIndex(of: true) ?? m, lastCovered = covered.lastIndex(of: true) ?? -1
        var added = 0, unplaced: [[TimedLyricWord]] = []

        // What no written line matched stays as heard. A word or two right against a placed
        // line is most likely part of it, misheard.
        for run in runs(covered) {
            let words = Array(heard[run])
            let touchesBefore = run.lowerBound > 0 && covered[run.lowerBound - 1] && heard[run.lowerBound].start - heard[run.lowerBound - 1].end < 1
            let touchesAfter = run.upperBound < m && covered[run.upperBound] && heard[run.upperBound].start - heard[run.upperBound - 1].end < 1
            if run.count > 2 || !(touchesBefore || touchesAfter) {
                lines += TimedLyricWord.phrases(words).map { Line(words: $0, origin: .heard) }
                unplaced.append(words)
            }
            // A passage inside the song, or a long one at either end, that no lyric has.
            if run.count >= 8 || run.count >= 4 && run.lowerBound > firstCovered && run.upperBound <= lastCovered { added += run.count }
        }

        lines.sort { ($0.words.first?.start ?? 0) < ($1.words.first?.start ?? 0) }
        lines = monotonic(once(lines))
        var uses: [String: Int] = [:]
        for line in lines { switch line.origin { case .online(let id), .filled(let id): uses[id, default: 0] += 1; case .heard: break } }
        let sources = pieces.map(\.id).filter { uses[$0] != nil }.sorted { uses[$0]! > uses[$1]! }
        return Result(lines: lines, onlineShare: Double(onlineWords) / Double(m), addedShare: Double(added) / Double(m), sources: sources, used: used, unplaced: unplaced)
    }

    /// A written line as compared: its words' letters, or "" for a section name or a line without words.
    public static func signature(_ text: String) -> String {
        guard !isLabel(text.trimmingCharacters(in: .whitespaces)) else { return "" }
        return text.split(whereSeparator: \.isWhitespace).map { LyricAlignment.key(String($0)) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    private static let section = "(?:intro|outro|verse|chorus|pre-?chorus|post-?chorus|hook|bridge|refrain|interlude|instrumental)"
    /// Section names some lyrics carry as lines ("Chorus:", "(Verse 2)").
    static func isLabel(_ text: String) -> Bool {
        // "[Verse 2: Ye]", "(Chorus)"; "Chorus x2", "Verse 1"; "Bridge (Juno):".
        [#"^[\[(]\s*"# + section + #"\b[^\])]*[\])]$"#, "^" + section + #"(?:\s*\d+)?(?:\s*[x×]\s*\d+)?\s*:?$"#, "^" + section + #"\b[^:]{0,40}:$"#]
            .contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// The longest a written line is taken to be before it is cut into sung lines (a long rap
    /// line stays whole).
    static let longestLine = 16
    /// A written line as it is sung: section names inside it dropped, and an overlong line (a
    /// lyric pasted as one wall of text, a whole verse on one line) cut at sentence ends, then,
    /// in a wall of text, where a new line starts with a capital, then at commas, then into
    /// even parts.
    public static func sungLines(_ text: String) -> [String] {
        // "(Chorus)", "[Verse 2: Juno Reyes]", "(Hook x2)" inside the text; not "(Hook me up)".
        let labels = #"[\[(]\s*"# + section + #"(?:\s*\d+)?(?:\s*[x×]\s*\d+)?(?:\s*[:\-–]\s*[^\])]{0,40})?\s*[\])]\s*:?"#
        var result: [String] = []
        for part in text.replacingOccurrences(of: labels, with: "\n", options: [.regularExpression, .caseInsensitive]).components(separatedBy: .newlines) {
            let clean = part.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty, !isLabel(clean) else { continue }
            result += cut(clean.split(whereSeparator: \.isWhitespace).map(String.init))
        }
        return result
    }
    private static func cut(_ words: [String]) -> [String] {
        guard words.count > longestLine else { return [words.joined(separator: " ")] }
        // "I" and its contractions are capitals inside a line too; so is the second word of a name.
        let pronoun: Set<String> = ["i", "im", "ill", "ive", "id", "ima", "imma"]
        func capital(_ word: String) -> Bool { word.first(where: \.isLetter)?.isUppercase ?? false }
        var rules: [(Int) -> Bool] = [{ i in words[i - 1].last.map { ".!?;:".contains($0) } ?? false }]
        // Capitals mark where lines began only in a wall of text; in one long line they are names.
        if words.count > 24 { rules.append { i in capital(words[i]) && !pronoun.contains(LyricAlignment.key(words[i])) && !capital(words[i - 1]) } }
        rules.append { i in words[i - 1].hasSuffix(",") }
        for rule in rules {
            var parts: [[String]] = [[words[0]]]
            for i in 1..<words.count { if rule(i) { parts.append([words[i]]) } else { parts[parts.count - 1].append(words[i]) } }
            // A word or two on their own belong with the line before.
            var merged: [[String]] = []
            for part in parts { if part.count < 3, !merged.isEmpty { merged[merged.count - 1] += part } else { merged.append(part) } }
            if merged.count > 1, merged[0].count < 3 { merged[1] = merged[0] + merged[1]; merged.removeFirst() }
            if merged.count > 1 { return merged.flatMap(cut) }
        }
        let count = Int((Double(words.count) / 10).rounded(.up)), size = Int((Double(words.count) / Double(count)).rounded(.up))
        return stride(from: 0, to: words.count, by: size).map { words[$0..<min($0 + size, words.count)].joined(separator: " ") }
    }

    /// Where one written line was sung: the whole line fitted against any stretch of the
    /// transcript within `range`, keeping each stretch that fits well and tightly.
    private static func find(_ line: Int, rows: [Int], scorer: LyricAlignment.Scorer, heard: [TimedLyricWord], within range: Range<Int>) -> [Hit] {
        let n = rows.count, m = range.count, base = range.lowerBound, width = m + 1
        guard n > 0, m > 0 else { return [] }
        var score = [Int](repeating: 0, count: (n + 1) * width), move = [UInt8](repeating: 0, count: (n + 1) * width)
        for i in 1...n { score[i * width] = -i; move[i * width] = 1 }
        for i in 1...n {
            for j in 1...m {
                let pair = scorer.score(rows[i - 1], base + j - 1)
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
                    let pair = scorer.score(rows[i - 1], base + j - 1)
                    matched += 1; total += pair; if pair == 3 { exact += 1 }
                    if final < 0 { final = base + j - 1 }; first = base + j - 1
                    i -= 1; j -= 1
                case 0: i -= 1; j -= 1
                case 1: i -= 1
                default: j -= 1
                }
            }
            guard matched >= required, first >= 0, seen.insert(first * (heard.count + 1) + final).inserted else { continue }
            // Short lines must be heard exactly; any line must be sung as one tight phrase.
            if n <= 2 && exact < n { continue }
            let span = final - first + 1
            guard Double(matched) >= Double(span) * 0.5, heard[final].end - heard[first].start <= Double(n) * 1.6 + 4 else { continue }
            let weight = Double(total) - 0.5 * Double(n - matched) - 0.5 * Double(span - matched)
            if weight > 0 { hits.append(.init(line: line, first: first, last: final, matched: matched, weight: weight)) }
        }
        return hits
    }

    /// The most lines of one lyric sung one after another in its order, and the words heard in them.
    private static func longestRun(_ ids: [Int], hits: [Int: [Hit]], heard: [TimedLyricWord]) -> (lines: Int, words: Int) {
        var best = (lines: 0, words: 0)
        var previous: [(hit: Hit, lines: Int, words: Int)] = []
        for id in ids {
            var current: [(hit: Hit, lines: Int, words: Int)] = []
            for hit in hits[id] ?? [] {
                var run = (lines: 1, words: hit.matched)
                for p in previous where p.hit.last < hit.first && heard[hit.first].start - heard[p.hit.last].end < 10 && p.lines + 1 > run.lines {
                    run = (p.lines + 1, p.words + hit.matched)
                }
                current.append((hit, run.lines, run.words))
                if run.lines > best.lines || run.lines == best.lines && run.words > best.words { best = run }
            }
            previous = current
        }
        return best
    }

    /// The lines a lyric has between two placed lines, when the recognizer missed them but the
    /// audio between has room for them (or heard words that fit them). A lyric with times puts
    /// them where its own timing does, stretched to fit how this version is sung.
    private static func between(_ a: Hit, _ b: Hit, _ c: Context) -> Filled? {
        for place in c.written[a.line].places where c.relevant[place.piece] {
            let ids = c.order[place.piece], after = place.line, stamps = c.times[place.piece]
            let upper = min(after + (stamps == nil ? 4 : 8), ids.count - 1)
            guard after + 2 <= upper, let target = (after + 2...upper).first(where: { ids[$0] == b.line }) else { continue }
            let missing = ids[(after + 1)..<target].map { c.written[$0] }
            let count = missing.reduce(0) { $0 + $1.words.count }
            let begin = c.heard[a.last].end, end = c.heard[b.first].start, room = end - begin
            let gap = a.last + 1 < b.first ? Array(c.heard[(a.last + 1)..<b.first]) : []
            let id = c.pieces[place.piece].id, texts = missing.map(\.text), words = (a.last + 1)..<b.first
            // Where the lyric's times put the missing lines, when this version sings the stretch
            // at about the lyric's pace.
            let mapped: [Double]? = stamps.flatMap { t in
                let from = t[after], to = t[target], start = c.heard[a.first].start, stop = c.heard[b.first].start
                guard to > from, stop > start else { return nil }
                let scale = (stop - start) / (to - from)
                guard scale > 0.75 && scale < 1.33 || abs((stop - start) - (to - from)) <= 3 else { return nil }
                return ((after + 1)..<target).map { start + (t[$0] - from) * scale }
            }
            // Past the usual four lines only on the lyric's own timing.
            if target - after > 5 && mapped == nil { continue }
            // Room to sing them besides the usual pause between lines, and not so much that the
            // song clearly went somewhere else.
            let fits = mapped != nil ? room >= Double(count) * 0.25 : room >= Double(count) * 0.3 + 1.5 && room <= Double(count) * 1.0 + 6
            if gap.isEmpty {
                guard fits else { continue }
                let filled = mapped.map { timed(texts, at: $0, from: begin + 0.05, to: end - 0.05) } ?? spread(texts, from: begin + 0.05, to: end - 0.05)
                return (filled.map { Line(words: $0, origin: .filled(id)) }, texts, words)
            }
            let lines = texts.enumerated().map { LyricAlignment.Line(time: mapped?[$0.offset], text: $0.element) }
            let aligned = LyricAlignment.align(lines, recognized: gap, after: begin)
            let plausible = gap.count <= count * 2 && gap.count * 3 >= count && (mapped != nil || room <= Double(count) * 1.0 + 6)
            // The words heard there must sound like these lines (misheard), not be other words
            // altogether: a mashup's verse from another song stays to be looked for.
            let pairs = (aligned.matched * Double(count)).rounded()
            guard aligned.matched >= 0.25 || plausible, pairs >= max(1, Double(gap.count) * 0.15) else { continue }
            let filled = aligned.lines.map { words in
                Line(words: words.map { .init(start: min(max($0.start, begin), end), end: min(max($0.end, begin), end), text: $0.text) }, origin: .filled(id))
            }
            return (filled, texts, words)
        }
        return nil
    }

    /// Up to three lines of a lyric just before the first placed line (or just after the last)
    /// that the recognizer heard too poorly to place alone, kept when the words heard right
    /// there fit them. Lines with nothing heard there are left out: a shorter version may not
    /// sing them.
    private static func edge(_ hit: Hit, leading: Bool, _ c: Context) -> Filled? {
        let heard = c.heard
        let available = leading ? 0..<hit.first : (hit.last + 1)..<heard.count
        guard !available.isEmpty else { return nil }
        for place in c.written[hit.line].places where c.relevant[place.piece] {
            let ids = c.order[place.piece]
            for k in stride(from: 3, through: 1, by: -1) {
                let range = leading ? (place.line - k)..<place.line : (place.line + 1)..<(place.line + 1 + k)
                guard range.lowerBound >= 0, range.upperBound <= ids.count else { continue }
                let texts = range.map { c.written[ids[$0]].text }
                let count = range.reduce(0) { $0 + c.written[ids[$1]].words.count }
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
                let id = c.pieces[place.piece].id
                return (aligned.lines.map { Line(words: $0, origin: .filled(id)) }, texts, low..<(high + 1))
            }
        }
        return nil
    }

    /// Whether heard words just repeat a placed line: sung right next to it, and mostly its words.
    private static func repeats(_ run: [TimedLyricWord], _ line: Line) -> Bool {
        guard line.origin != .heard, let first = run.first, let last = run.last, let start = line.words.first?.start, let end = line.words.last?.end,
              first.start - end <= 4, start - last.end <= 4 else { return false }
        let count = Double(line.words.count)
        let pairs = (LyricAlignment.align([.init(time: nil, text: line.text)], recognized: run).matched * count).rounded()
        return run.count <= 2 ? pairs >= Double(run.count) : pairs >= 2 && pairs >= Double(run.count) * 0.5
    }

    /// The stretches of heard words not yet accounted for.
    private static func runs(_ covered: [Bool]) -> [Range<Int>] {
        var result: [Range<Int>] = [], j = 0
        while j < covered.count {
            guard !covered[j] else { j += 1; continue }
            var stop = j
            while stop < covered.count && !covered[stop] { stop += 1 }
            result.append(j..<stop); j = stop
        }
        return result
    }

    /// A lyric's line times with the lines between two timed ones spread evenly; nil without times.
    private static func interpolated(_ stamps: [Double?]) -> [Double]? {
        let known = stamps.indices.filter { stamps[$0] != nil }
        guard let firstKnown = known.first, let lastKnown = known.last else { return nil }
        var result = stamps.map { $0 ?? 0 }
        for i in 0..<firstKnown { result[i] = max(0, stamps[firstKnown]! - Double(firstKnown - i) * 3) }
        for (a, b) in zip(known, known.dropFirst()) where b > a + 1 {
            for i in (a + 1)..<b { result[i] = stamps[a]! + (stamps[b]! - stamps[a]!) * Double(i - a) / Double(b - a) }
        }
        for i in (lastKnown + 1)..<max(lastKnown + 1, stamps.count) { result[i] = stamps[lastKnown]! + Double(i - lastKnown) * 3 }
        return result
    }

    /// Lines starting at the times given, each lasting until the next (no longer than it takes
    /// to sing it), kept inside `begin...end`.
    private static func timed(_ texts: [String], at starts: [Double], from begin: Double, to end: Double) -> [[TimedLyricWord]] {
        var result: [[TimedLyricWord]] = [], cursor = begin
        for (k, text) in texts.enumerated() {
            let start = min(max(starts[k], cursor), end)
            let next = k + 1 < starts.count ? min(max(starts[k + 1], start), end) : end
            let words = TimedLyricWord.estimated(text, start: start, end: max(next - 0.05, start + 0.2)).map {
                TimedLyricWord(start: min($0.start, end), end: min($0.end, end), text: $0.text)
            }
            result.append(words); cursor = words.last?.end ?? start
        }
        return result
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

    /// The same written line placed twice at once (two ways of reaching it) is shown once.
    private static func once(_ lines: [Line]) -> [Line] {
        var result: [Line] = []
        for line in lines where !line.words.isEmpty {
            if let last = result.last, last.origin != .heard, line.origin != .heard, signature(last.text) == signature(line.text),
               let end = last.words.last?.end, let start = line.words.first?.start, start < end - 0.05 { continue }
            result.append(line)
        }
        return result
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
