import Foundation

public struct LyricCandidate: Identifiable, Equatable, Sendable {
    public var id: String
    public var source: String
    public var title: String
    public var artist: String
    public var duration: Double?
    public var text: String
    public init(id: String, source: String, title: String, artist: String, duration: Double?, text: String) {
        self.id = id; self.source = source; self.title = title; self.artist = artist; self.duration = duration; self.text = text
    }
    public var lines: [LyricLine] { LyricsParser.parse(text) }
    public var synced: Bool { lines.contains { $0.time != nil } }
    public var wordTimed: Bool { lines.contains { !$0.words.isEmpty } }
    public var kind: String { wordTimed ? "Word-timed" : synced ? "Line-timed" : "Plain text" }
    public var preview: String { lines.prefix(3).map(\.text).joined(separator: " / ") }
}

public protocol LyricsSearching: Sendable {
    /// Throws only when the lyrics service could not be reached at all, so "none found" and
    /// "no connection" are never confused.
    func candidates(title: String, artists: [String], duration: Double) async throws -> [LyricCandidate]
    /// Lyrics that may hold parts of the song no lyric found by name accounts for: the songs a
    /// mashup's title names, more of the artists' songs, and songs named after `phrases` sung in
    /// those parts. Unchecked: `LyricParts.vet` keeps those really sung.
    func parts(title: String, artists: [String], phrases: [String]) async -> [LyricCandidate]
}
extension LyricsSearching {
    public func parts(title: String, artists: [String], phrases: [String]) async -> [LyricCandidate] { [] }
}

/// LRCLIB, asked several ways at once (the name as chosen and cleaned up, each artist, the
/// title alone, free text), keeping every answer.
public struct LyricsSearch: LyricsSearching {
    public init() {}
    private struct Row: Decodable { var id: Int; var trackName: String; var artistName: String; var duration: Double?; var plainLyrics: String?; var syncedLyrics: String? }
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "Scout/1.0 (personal lyrics lookup)"]
        return URLSession(configuration: config)
    }()
    /// nil when LRCLIB couldn't be reached even after retrying; [] when it answered with nothing.
    private func rows(_ items: [String: String]) async -> [Row]? {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url, let (data, http) = await Net.get(url, session: Self.session) else { return nil }
        guard http.statusCode == 200, data.count < 10_000_000 else { return [] }
        return (try? JSONDecoder().decode([Row].self, from: data)) ?? []
    }
    static func queries(title: String, artists: [String]) -> [[String: String]] {
        var titles: [String] = []
        for value in [title] + Suggestions.nameVariants(title).suffix(2) where !titles.contains(where: { AlbumKey.normalize($0) == AlbumKey.normalize(value) }) { titles.append(value) }
        let names = Array(artists.filter { !$0.isEmpty && $0 != "Unknown artist" }.prefix(2))
        let exact = titles.first ?? title, clean = titles.last ?? title
        // Most useful first, so the cap never drops the title-only search.
        var result: [[String: String]] = []
        if let main = names.first {
            result.append(["track_name": exact, "artist_name": main])
            result.append(["track_name": clean, "artist_name": main])
            result.append(["q": clean + " " + main])
        }
        result.append(["track_name": clean])
        for other in names.dropFirst() { result.append(["track_name": exact, "artist_name": other]); result.append(["track_name": clean, "artist_name": other]) }
        if let main = names.first { result.append(["q": exact + " " + main]) }
        var seen = Set<String>()
        return result.filter { seen.insert($0.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "&")).inserted }.prefix(8).map { $0 }
    }
    /// Every query's answer, three at a time: LRCLIB drops bursts of parallel requests.
    private func answers(_ queries: [[String: String]]) async -> [[Row]?] {
        var answers: [[Row]?] = []
        for start in stride(from: 0, to: queries.count, by: 3) {
            if Task.isCancelled { break }
            let batch = Array(queries[start..<min(start + 3, queries.count)])
            answers += await withTaskGroup(of: (Int, [Row]?).self) { group in
                for (index, query) in batch.enumerated() { group.addTask { (index, await rows(query)) } }
                var all: [(Int, [Row]?)] = []
                for await answer in group { all.append(answer) }
                return all.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }
        return answers
    }
    /// One candidate per row: its synced lyrics, or its plain text when that is all it has.
    private static func lyrics(_ answers: [[Row]?]) -> [LyricCandidate] {
        var seen = Set<Int>(), result: [LyricCandidate] = []
        for row in answers.compactMap({ $0 }).flatMap({ $0 }) where seen.insert(row.id).inserted {
            if let synced = row.syncedLyrics, !synced.isEmpty {
                result.append(.init(id: "lrclib-\(row.id)-synced", source: "LRCLIB", title: row.trackName, artist: row.artistName, duration: row.duration, text: synced))
            } else if let plain = row.plainLyrics, !plain.isEmpty {
                result.append(.init(id: "lrclib-\(row.id)-plain", source: "LRCLIB", title: row.trackName, artist: row.artistName, duration: row.duration, text: plain))
            }
        }
        return result
    }
    public func candidates(title: String, artists: [String], duration: Double) async throws -> [LyricCandidate] {
        let answers = await answers(Self.queries(title: title, artists: artists))
        guard answers.contains(where: { $0 != nil }) else { throw ScoutError.message("Couldn't reach LRCLIB. Check the connection and retry.") }
        return Self.ranked(Self.lyrics(answers), title: title, duration: duration)
    }
    public func parts(title: String, artists: [String], phrases: [String]) async -> [LyricCandidate] {
        Self.lyrics(await answers(Self.partQueries(title: title, artists: artists, phrases: phrases)))
    }
    /// The songs a mashup's title names, the artists' songs, then songs named after each phrase
    /// (by the artist, and by anyone: a mashup's other songs are often someone else's).
    static func partQueries(title: String, artists: [String], phrases: [String]) -> [[String: String]] {
        let names = Array(artists.filter { !$0.isEmpty && $0 != "Unknown artist" }.prefix(2))
        var result: [[String: String]] = []
        for part in LyricParts.titleParts(title) {
            if let main = names.first { result.append(["track_name": part, "artist_name": main]) }
            result.append(["track_name": part])
        }
        for phrase in phrases {
            if let main = names.first { result.append(["track_name": phrase, "artist_name": main]) }
            result.append(["track_name": phrase])
        }
        for name in names { result.append(["q": name]) }
        var seen = Set<String>()
        return result.filter { seen.insert($0.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value.lowercased() }.joined(separator: "&")).inserted }.prefix(18).map { $0 }
    }
    /// Closest length first, then the closer title, then better timing.
    public static func ranked(_ candidates: [LyricCandidate], title: String, duration: Double) -> [LyricCandidate] {
        let wanted = MusicSearchQuery.normalize(title)
        func score(_ c: LyricCandidate) -> Double {
            var s = 0.0
            if duration > 0, let d = c.duration { s += max(0, 30 - abs(d - duration) * 3) }
            if MusicSearchQuery.normalize(c.title) == wanted { s += 20 } else if MusicSearchQuery.normalize(c.title).contains(wanted) { s += 8 }
            s += c.wordTimed ? 6 : c.synced ? 4 : 0
            return s
        }
        return candidates.enumerated().sorted { a, b in
            let x = score(a.element), y = score(b.element)
            return x == y ? a.offset < b.offset : x > y
        }.map(\.element)
    }
}

/// Hears the words in a song, with their times. On the iPhone's own speech model in the app;
/// a fixture in the simulator tests.
public protocol AudioListening: Sendable {
    func words(in file: URL, duration: Double, locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws -> [TimedLyricWord]
}
public struct OnDeviceListener: AudioListening {
    public init() {}
    public func words(in file: URL, duration: Double, locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws -> [TimedLyricWord] {
        // No vocabulary hint: the transcript must stay a fair yardstick for every candidate.
        try await LocalLyricTranscriber.recognize(file, duration: duration, locale: locale, vocabulary: [], progress: progress)
    }
}

/// How well a set of lyrics fits what was heard in the audio.
public enum LyricsMatch {
    /// Below this, a candidate is not considered this song's lyrics.
    public static let threshold = 0.3
    /// Share of the candidate's words found, in order, in the transcript; reduced when the
    /// candidate is much shorter than what was sung (a chorus-only or partial lyric).
    public static func score(_ candidate: LyricCandidate, heard: [TimedLyricWord]) -> Double { fit(candidate, heard: heard).score }
    /// `score` as above; `explained`, the share of the heard words the candidate accounts for in
    /// its own order (what a version with moved, repeated or cut parts loses).
    public static func fit(_ candidate: LyricCandidate, heard: [TimedLyricWord]) -> (score: Double, explained: Double) {
        let lines = candidate.lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let words = lines.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        let sung = heard.filter { !LyricAlignment.key($0.text).isEmpty }.count
        guard words > 0, sung > 0 else { return (0, 0) }
        // Ignore line times here: a wrong version's times must not be what decides.
        let result = LyricAlignment.align(lines.map { .init(time: nil, text: $0.text) }, recognized: heard)
        let coverage = Double(words) / Double(sung)
        return (result.matched * min(1, coverage / 0.4), min(1, result.matched * Double(words) / Double(sung)))
    }
    /// The lyrics pieced together from the audio win when written lines account for clearly
    /// more of what was sung than the best whole lyric does: this version moved, repeated, cut
    /// or added parts, or is a different length. Otherwise the whole lyric keeps its lines.
    /// `explained`: the best lyric's `fit(...).explained`.
    public static func prefersAssembly(_ assembly: LyricAssembly.Result, over best: LyricCandidate?, explained: Double?) -> Bool {
        guard assembly.onlineLines >= 2, assembly.onlineShare >= 0.3 else { return false }
        guard let best else { return true }
        // Parts moved or sung more often: the whole lyric, in its order, accounts for less.
        if assembly.onlineShare >= (explained ?? 0) + 0.15 { return true }
        // Parts this version has that the lyric doesn't.
        if assembly.addedShare >= 0.2 { return true }
        // Parts of the lyric this version doesn't have (a shorter version, a cut verse).
        let lines = Set(best.lines.flatMap { LyricAssembly.sungLines($0.text) }.map(LyricAssembly.signature).filter { !$0.isEmpty })
        return lines.count >= 4 && Double(lines.subtracting(assembly.used).count) >= Double(lines.count) * 0.3
    }
    /// The best candidate at or above the threshold; ties go to better timing, then list order.
    public static func best(_ candidates: [LyricCandidate], scores: [String: Double]) -> LyricCandidate? {
        candidates.enumerated()
            .filter { (scores[$0.element.id] ?? 0) >= threshold }
            .max { a, b in
                let x = scores[a.element.id] ?? 0, y = scores[b.element.id] ?? 0
                if abs(x - y) > 0.05 { return x < y }
                let rank: (LyricCandidate) -> Int = { $0.wordTimed ? 2 : $0.synced ? 1 : 0 }
                if rank(a.element) != rank(b.element) { return rank(a.element) < rank(b.element) }
                return a.offset > b.offset
            }?.element
    }
}

/// Turns the chosen lyrics into what gets saved. Runs on this iPhone only.
public enum LyricsMaker {
    /// The lyrics saved for a song, and where they came from.
    public struct Made: Equatable, Sendable {
        public var text: String
        public var source: String
    }
    /// Scout's own lyrics for a song, from what was heard and the lyrics found.
    public struct Generated: Equatable, Sendable {
        public var lrc: String
        public var source: String
        /// What was heard, with the written lines found where they were sung.
        public var assembly: LyricAssembly.Result
        /// The lyric used whole, when this version is sung just as it is written: every one of
        /// its lines kept (even one too quiet to hear), each word timed from the audio.
        public var whole: LyricCandidate?
        /// Per lyric found by name: `LyricsMatch.fit`'s score and explained share.
        public var scores: [String: Double]
        public var explained: [String: Double]
    }

    /// The generated lyrics. Lines of the lyrics found take their place where they were sung,
    /// in the order and as often as this version sings them; `parts`, lyrics found for parts of
    /// the song (a mashup's other songs), fill in what they were found for; the rest stays as
    /// heard. A version sung just like one lyric keeps that lyric whole, timed word by word.
    public static func generate(heard: [TimedLyricWord], pieces: [LyricCandidate], parts: [LyricCandidate] = []) -> Generated {
        var scores: [String: Double] = [:], explained: [String: Double] = [:]
        for piece in pieces {
            let fit = LyricsMatch.fit(piece, heard: heard)
            scores[piece.id] = fit.score; explained[piece.id] = fit.explained
        }
        let known = Set(pieces.map(\.id)), extra = parts.filter { !known.contains($0.id) }
        let assembly = LyricAssembly.assemble(heard: heard, pieces: pieces + extra, trusted: Set(extra.map(\.id)))
        if let best = LyricsMatch.best(pieces, scores: scores), !LyricsMatch.prefersAssembly(assembly, over: best, explained: explained[best.id]),
           let lrc = timed(best.text, heard: heard) {
            return Generated(lrc: lrc, source: best.source + ", timed to your audio", assembly: assembly, whole: best, scores: scores, explained: explained)
        }
        return Generated(lrc: assembly.lrc, source: source(assembly, pieces: pieces + extra), assembly: assembly, whole: nil, scores: scores, explained: explained)
    }
    static func source(_ assembly: LyricAssembly.Result, pieces: [LyricCandidate]) -> String {
        guard assembly.onlineLines > 0 else { return "Generated from your audio" }
        var names: [String] = []
        for id in assembly.sources { if let name = pieces.first(where: { $0.id == id })?.source, !names.contains(name) { names.append(name) } }
        return "Pieced from your audio and " + (names.isEmpty ? "lyrics online" : names.joined(separator: " & "))
    }

    /// Lyrics as written, every word timed from the audio: plain text (even one wall of it) cut
    /// into sung lines, and line times kept where they fit this version. nil when too little of
    /// it was heard to time it.
    public static func timed(_ text: String, heard: [TimedLyricWord]) -> String? {
        let lines = LyricsParser.parse(text).flatMap { line in
            LyricAssembly.sungLines(line.text).enumerated().map { LyricAlignment.Line(time: $0.offset == 0 ? line.time : nil, text: $0.element) }
        }
        guard !lines.isEmpty, !heard.isEmpty else { return nil }
        let anchored = LyricAlignment.align(lines, recognized: heard)
        // Line times from a version of another length (a longer intro, a cut verse) hold every
        // word away from where it was sung here; try again without them.
        if lines.contains(where: { $0.time != nil }) {
            let free = LyricAlignment.align(lines.map { .init(time: nil, text: $0.text) }, recognized: heard)
            if free.matched >= 0.25 && free.matched > anchored.matched + 0.15 { return free.lrc }
        }
        // Too little heard means the words would be guessed.
        return anchored.matched >= 0.25 ? anchored.lrc : nil
    }

    /// `heard`: the song's transcript if Scout already listened; otherwise it listens now.
    /// `pieces`: lyrics found for the song by its name; `parts`: lyrics found for parts of it.
    public static func finalize(_ draft: SongDraft, locale: Locale, heard: [TimedLyricWord]?, pieces: [LyricCandidate] = [], parts: [LyricCandidate] = [],
                                listener: AudioListening, progress: @escaping @Sendable (String) -> Void) async throws -> Made? {
        func listen() async throws -> [TimedLyricWord] {
            if let heard { return heard }
            return try await listener.words(in: draft.song.file, duration: draft.song.duration, locale: locale, progress: progress)
        }
        switch draft.lyrics {
        case .none: return nil
        case .generate:
            var words: [TimedLyricWord] = []
            // Listening can fail (no speech model for the language); the song is saved all the same.
            do { words = try await listen() } catch is CancellationError { throw CancellationError() } catch {}
            if !words.isEmpty {
                progress("Piecing the lyrics together…")
                let made = generate(heard: words, pieces: pieces, parts: parts)
                if !made.lrc.isEmpty { return Made(text: made.lrc, source: made.source) }
            }
            // Nothing heard (an instrumental, or no listening): the lyrics that came with the
            // song, or lyrics found for a song of this length.
            return fallback(pieces, duration: draft.song.duration).map { Made(text: $0.text, source: $0.source) }
        case .text(let text, let source):
            let lines = LyricsParser.parse(text)
            // Word timing is added only where the words are not timed yet; the text stays as chosen.
            guard draft.timeWords, !lines.isEmpty, !lines.contains(where: { !$0.words.isEmpty }), draft.song.duration > 0 else { return Made(text: text, source: source) }
            do {
                return Made(text: timed(text, heard: try await listen()) ?? text, source: source)
            } catch is CancellationError { throw CancellationError() }
            catch { return Made(text: text, source: source) }
        }
    }
    /// The lyrics that came with the song, or the first found for a song this long.
    static func fallback(_ pieces: [LyricCandidate], duration: Double) -> LyricCandidate? {
        if let own = pieces.first(where: { $0.id == "tagged" || $0.id == "source" }) { return own }
        return pieces.first { candidate in candidate.duration.map { duration > 0 && abs($0 - duration) <= 3 } ?? false }
    }
}
