import Foundation

/// Gives known lyric text real word times by aligning it to words recognized from the
/// audio. The lyric text is kept as written; only the times come from the recognizer.
public enum LyricAlignment {
    public struct Line: Equatable, Sendable {
        public var time: Double?
        public var text: String
        public init(time: Double?, text: String) { self.time = time; self.text = text }
    }
    public struct Result: Equatable, Sendable {
        public var lines: [[TimedLyricWord]]
        /// Share of lyric words that took a recognized time (the rest are interpolated).
        public var matched: Double
        public var lrc: String { lines.compactMap(TimedLyricWord.lrcLine).joined(separator: "\n") }
    }

    static func key(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
    /// How sung words are written down differently from how the recognizer spells them.
    static let spoken: [String: String] = [
        "gonna": "going", "wanna": "want", "gotta": "got", "tryna": "trying", "finna": "fixing",
        "cause": "because", "cuz": "because", "coz": "because", "cos": "because", "bc": "because",
        "til": "until", "till": "until", "em": "them", "ya": "you", "u": "you", "ur": "your",
        "n": "and", "da": "the", "tha": "the", "dat": "that", "dis": "this", "tho": "though", "thru": "through",
        "lil": "little", "bout": "about", "imma": "im", "ima": "im", "ok": "okay", "alright": "allright",
        "2": "to", "two": "to", "too": "to", "4": "for", "four": "for", "fore": "for",
    ]
    /// A rough sound of a word: consonants in order after the first letter, with common
    /// spellings of one sound made the same ("your"/"you're", "right"/"write", "know"/"no").
    static func sound(_ key: String) -> String {
        var s = key
        for (from, to) in [("ph", "f"), ("gh", ""), ("ck", "k"), ("wh", "w"), ("qu", "kw"), ("q", "k"), ("x", "ks"), ("z", "s"), ("c", "k")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        if s.hasPrefix("kn") || s.hasPrefix("wr") { s.removeFirst() }
        guard let first = s.first else { return "" }
        var out = String(first)
        for ch in s.dropFirst() where !"aeiouyw".contains(ch) && ch != out.last { out.append(ch) }
        return out
    }
    /// A word as compared: its letters, its everyday spelling and its rough sound.
    struct Form {
        let key: String, plain: String, sound: String, letters: [UInt8]
        init(_ key: String) { self.key = key; letters = Array(key.utf8); plain = LyricAlignment.spoken[key] ?? key; sound = LyricAlignment.sound(plain) }
    }
    /// Sung words drift from their written form ("gonna"/"going", "runnin'"/"running",
    /// "you're"/"your"). 3 is the same word, 2 a likely one, -1 a different word. Spellings a
    /// letter apart count only with the same first letter: "night" and "light" rhyme, they
    /// aren't one word misheard.
    static func similar(_ a: Form, _ b: Form) -> Int {
        if a.key.isEmpty || b.key.isEmpty { return -1 }
        if a.key == b.key { return 3 }
        if a.plain == b.plain { return 2 }
        let shorter = min(a.letters.count, b.letters.count), longer = max(a.letters.count, b.letters.count)
        if shorter >= 3 && a.letters[..<shorter] == b.letters[..<shorter] { return 2 }
        let allowed = max(1, shorter / 4)
        if shorter >= 4 && longer - shorter <= allowed && a.letters[0] == b.letters[0] && distance(a.letters, b.letters) <= allowed { return 2 }
        if longer >= 3 && !a.sound.isEmpty && a.sound == b.sound { return 2 }
        return -1
    }
    static func similar(_ a: String, _ b: String) -> Int { similar(Form(key(a)), Form(key(b))) }
    static func distance(_ x: [UInt8], _ y: [UInt8]) -> Int {
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var previous = Array(0...y.count), current = previous
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// Written words against heard words, each distinct pair compared once, and only pairs
    /// that can match at all (same first letter, everyday spelling or sound).
    struct Scorer {
        /// Per heard word, the id of its distinct form.
        private(set) var heard: [Int] = []
        private var heardForms: [Form] = []
        private var byFirst: [UInt8: [Int]] = [:], byPlain: [String: [Int]] = [:], bySound: [String: [Int]] = [:]
        private var rows: [String: Int] = [:]
        private var cells: [Int8] = []
        init(heard words: [String]) {
            var ids: [String: Int] = [:]
            for word in words {
                let k = LyricAlignment.key(word)
                if let id = ids[k] { heard.append(id); continue }
                let id = heardForms.count, form = Form(k)
                ids[k] = id; heard.append(id); heardForms.append(form)
                if let first = form.letters.first { byFirst[first, default: []].append(id) }
                byPlain[form.plain, default: []].append(id)
                if !form.sound.isEmpty { bySound[form.sound, default: []].append(id) }
            }
        }
        /// The row for a written word; it is compared to the heard words the first time.
        mutating func row(_ word: String) -> Int {
            let k = LyricAlignment.key(word)
            if let row = rows[k] { return row }
            let form = Form(k), row = rows.count
            rows[k] = row
            var line = [Int8](repeating: -1, count: heardForms.count)
            if let first = form.letters.first {
                for id in (byFirst[first] ?? []) + (byPlain[form.plain] ?? []) + (bySound[form.sound] ?? []) where line[id] < 0 {
                    line[id] = Int8(LyricAlignment.similar(form, heardForms[id]))
                }
            }
            cells += line
            return row
        }
        func score(_ row: Int, _ heardIndex: Int) -> Int { Int(cells[row * heardForms.count + heard[heardIndex]]) }
    }

    /// `window`: when lines already carry times, a recognized word further than this from
    /// its line's time cannot claim it, so common words do not jump across verses.
    /// `after`: no word is placed before this time (the end of whatever precedes these lines).
    public static func align(_ lines: [Line], recognized input: [TimedLyricWord], window: Double = 10, after floor: Double = 0) -> Result {
        let recognized = input.filter { $0.start.isFinite && $0.end >= $0.start && !key($0.text).isEmpty }.sorted { $0.start < $1.start }
        let words: [(line: Int, text: String, key: String)] = lines.enumerated().flatMap { index, line in
            line.text.split(whereSeparator: \.isWhitespace).map { (index, String($0), key(String($0))) }
        }
        let n = words.count, m = recognized.count
        var pairs: [Int: Int] = [:]
        if n > 0 && m > 0 {
            var scorer = Scorer(heard: recognized.map(\.text))
            let rows = words.map { scorer.row($0.text) }
            // Global alignment (Needleman–Wunsch) with skips on either side.
            let gap = -1
            let width = m + 1
            var score = [Int](repeating: 0, count: (n + 1) * width), move = [UInt8](repeating: 0, count: (n + 1) * width)
            for i in 1...n { score[i * width] = i * gap; move[i * width] = 1 }
            for j in 1...m { score[j] = j * gap; move[j] = 2 }
            for i in 1...n {
                let lyric = words[i - 1]
                let anchor = lines[lyric.line].time
                let row = i * width, above = row - width
                for j in 1...m {
                    var pair = lyric.key.isEmpty ? -1 : scorer.score(rows[i - 1], j - 1)
                    if pair > 0, let anchor, abs(recognized[j - 1].start - anchor) > window { pair = -1 }
                    let diagonal = score[above + j - 1] + pair, up = score[above + j] + gap, left = score[row + j - 1] + gap
                    if diagonal >= up && diagonal >= left { score[row + j] = diagonal; move[row + j] = pair > 0 ? 3 : 0 }
                    else if up >= left { score[row + j] = up; move[row + j] = 1 }
                    else { score[row + j] = left; move[row + j] = 2 }
                }
            }
            var i = n, j = m
            while i > 0 && j > 0 {
                switch move[i * width + j] {
                case 3: pairs[i - 1] = j - 1; i -= 1; j -= 1
                case 0: i -= 1; j -= 1
                case 1: i -= 1
                default: j -= 1
                }
            }
        }
        // Times for matched words, then interpolation between matched neighbours.
        var starts = [Double?](repeating: nil, count: n), ends = [Double?](repeating: nil, count: n)
        for (index, match) in pairs { starts[index] = recognized[match].start; ends[index] = recognized[match].end }
        var index = 0
        while index < n {
            guard starts[index] == nil else { index += 1; continue }
            var stop = index
            while stop < n && starts[stop] == nil { stop += 1 }
            let line = words[index].line
            let lower = index > 0 ? ends[index - 1] : nil
            let upper = stop < n ? starts[stop] : nil
            // Anchor a run to its line's own time when the line starts inside it.
            let lineStart = (index == 0 || words[index - 1].line != line) ? lines[line].time : nil
            var begin = max(lower ?? floor, lineStart ?? lower ?? floor)
            // A line time past the next word heard (a version sung faster than the lyric is timed)
            // would put these words after it: they go right after the words before instead.
            if let upper, begin > upper { begin = min(lower ?? floor, upper) }
            let finish: Double = {
                if let upper, upper > begin { return upper }
                let natural = begin + Double(stop - index) * 0.45
                return upper.map { max($0, begin) } ?? natural
            }()
            let run = Array(index..<stop)
            let weights = run.map { max(1, Double(words[$0].key.count)) + 1.5 }
            let total = weights.reduce(0, +)
            // Unmatched stretches longer than natural singing sit at their start, or, before
            // the first heard word, end right where it begins.
            let span = min(finish - begin, total * 0.12 + 0.4)
            var cursor = index == 0 && lower == nil && upper != nil && lineStart == nil ? max(begin, finish - span) : begin
            for (offset, word) in run.enumerated() {
                let length = span * weights[offset] / total
                starts[word] = cursor; ends[word] = cursor + length; cursor += length
            }
            index = stop
        }
        var result = [[TimedLyricWord]](repeating: [], count: lines.count)
        for (offset, word) in words.enumerated() {
            let start = starts[offset] ?? 0, end = max(start, ends[offset] ?? start)
            result[word.line].append(.init(start: start, end: end, text: word.text))
        }
        return Result(lines: result, matched: n == 0 ? 0 : Double(pairs.count) / Double(n))
    }
}

extension TimedLyricWord {
    /// One Enhanced LRC line: `[start]<t>word <t>word<end>`.
    public static func lrcLine(_ words: [TimedLyricWord]) -> String? {
        guard let first = words.first, let last = words.last else { return nil }
        func stamp(_ value: Double) -> String { let ms = Int((max(0, value) * 1000).rounded()); return String(format: "%02d:%02d.%03d", ms / 60000, ms / 1000 % 60, ms % 1000) }
        return "[\(stamp(first.start))]" + words.map { "<\(stamp($0.start))>" + $0.text }.joined(separator: " ") + "<\(stamp(last.end))>"
    }
}
