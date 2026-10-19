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
    public func candidates(title: String, artists: [String], duration: Double) async throws -> [LyricCandidate] {
        let queries = Self.queries(title: title, artists: artists)
        // Three at a time: LRCLIB drops bursts of parallel requests.
        var answers: [[Row]?] = []
        for start in stride(from: 0, to: queries.count, by: 3) {
            let batch = Array(queries[start..<min(start + 3, queries.count)])
            answers += await withTaskGroup(of: (Int, [Row]?).self) { group in
                for (index, query) in batch.enumerated() { group.addTask { (index, await rows(query)) } }
                var all: [(Int, [Row]?)] = []
                for await answer in group { all.append(answer) }
                return all.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }
        guard answers.contains(where: { $0 != nil }) else { throw ScoutError.message("Couldn't reach LRCLIB. Check the connection and retry.") }
        var seen = Set<Int>(), result: [LyricCandidate] = []
        for row in answers.compactMap({ $0 }).flatMap({ $0 }) where seen.insert(row.id).inserted {
            // Synced first; a row with only plain text is offered as plain.
            if let synced = row.syncedLyrics, !synced.isEmpty {
                result.append(.init(id: "lrclib-\(row.id)-synced", source: "LRCLIB", title: row.trackName, artist: row.artistName, duration: row.duration, text: synced))
            } else if let plain = row.plainLyrics, !plain.isEmpty {
                result.append(.init(id: "lrclib-\(row.id)-plain", source: "LRCLIB", title: row.trackName, artist: row.artistName, duration: row.duration, text: plain))
            }
        }
        return Self.ranked(result, title: title, duration: duration)
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
        let lines = Set(best.lines.map { LyricAssembly.signature($0.text) }.filter { !$0.isEmpty })
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

/// Turns the chosen lyrics into what gets saved: generates them from the audio, or measures
/// real word times for line-timed lyrics. Runs on this iPhone only.
public enum LyricsMaker {
    /// `heard`: the song's transcript if Scout already listened; otherwise it listens now.
    /// `pieces`: lyrics found for the song; generated lyrics take their lines where they were sung.
    public static func finalize(_ draft: SongDraft, locale: Locale, heard: [TimedLyricWord]?, pieces: [LyricCandidate] = [], listener: AudioListening,
                                progress: @escaping @Sendable (String) -> Void) async throws -> String? {
        func listen() async throws -> [TimedLyricWord] {
            if let heard, !heard.isEmpty { return heard }
            return try await listener.words(in: draft.song.file, duration: draft.song.duration, locale: locale, progress: progress)
        }
        switch draft.lyrics {
        case .none: return nil
        case .generate:
            let text = LyricAssembly.assemble(heard: try await listen(), pieces: pieces).lrc
            guard !text.isEmpty else { throw ScoutError.message("No vocals could be recognized in this audio.") }
            return text
        case .text(let text, _):
            let lines = LyricsParser.parse(text)
            // Word timing is added only where the words are not timed yet; the text stays as chosen.
            guard draft.timeWords, !lines.isEmpty, !lines.contains(where: { !$0.words.isEmpty }), draft.song.duration > 0 else { return text }
            let known = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            do {
                let words = try await listen()
                let anchored = LyricAlignment.align(known.map { .init(time: $0.time, text: $0.text) }, recognized: words)
                // Line times from a version of another length (a longer intro, a cut verse) hold
                // every word away from where it was sung here; try again without them.
                if known.contains(where: { $0.time != nil }) {
                    let free = LyricAlignment.align(known.map { .init(time: nil, text: $0.text) }, recognized: words)
                    if free.matched >= 0.25 && free.matched > anchored.matched + 0.15 { return free.lrc }
                }
                // Too little heard means the words would be guessed; keep the lyrics as chosen.
                return anchored.matched >= 0.25 ? anchored.lrc : text
            } catch is CancellationError { throw CancellationError() }
            catch { return text }
        }
    }
}
