import XCTest
@testable import ScoutKit

/// A released lyric, and versions of the song (leaks, demos, edits) sung differently from it.
final class LyricAssemblyTests: XCTestCase {
    static let v1 = ["Streetlights hum along the avenue", "I count the windows till I find you"]
    static let chorus = ["Hold on to the night bus", "Carry me home before the morning"]
    static let v2 = ["Paper tickets folded in my pocket", "Every stop a little closer to you"]
    static let bridge = ["Don't let the driver turn around"]
    static let released: LyricCandidate = {
        let lines = v1 + chorus + v2 + chorus + bridge + chorus
        let text = lines.enumerated().map { String(format: "[%02d:%02d.00]", ($0.offset * 4 + 10) / 60, ($0.offset * 4 + 10) % 60) + $0.element }.joined(separator: "\n")
        return .init(id: "released", source: "LRCLIB", title: "Night Bus", artist: "Ines Vale", duration: 200, text: text)
    }()

    /// What the recognizer hears: each line's words 0.4 s apart, lowercased and unpunctuated,
    /// with `pause` seconds between lines. A line of "" is a stretch of silence.
    static func sing(_ lines: [String], from start: Double = 5, pause: Double = 1.2) -> [TimedLyricWord] {
        var words: [TimedLyricWord] = [], time = start
        for line in lines {
            if line.isEmpty { time += 4; continue }
            for word in line.split(separator: " ") {
                let text = word.lowercased().filter { $0.isLetter || $0 == "'" }
                words.append(.init(start: time, end: time + 0.32, text: text)); time += 0.4
            }
            time += pause
        }
        return words
    }
    func texts(_ result: LyricAssembly.Result) -> [String] { result.lines.map(\.text) }
    func explained(_ heard: [TimedLyricWord]) -> Double { LyricsMatch.fit(Self.released, heard: heard).explained }

    func testVersesInAnotherOrderAndAnExtraChorusComeOutAsSungWithTheWrittenSpelling() {
        let sung = Self.v2 + Self.chorus + Self.v1 + Self.chorus + Self.chorus
        // The recognizer's own spellings.
        var heardLines = sung
        heardLines[4] = "streetlight hum along the avenue"
        heardLines[5] = "i count the windows til i find you"
        heardLines[3] = "carry me home before the mornin"
        let heard = Self.sing(heardLines)
        let result = LyricAssembly.assemble(heard: heard, pieces: [Self.released])
        XCTAssertEqual(texts(result), sung)
        XCTAssertTrue(result.lines.allSatisfy { $0.origin == .online("released") })
        XCTAssertGreaterThan(result.onlineShare, 0.95)
        XCTAssertEqual(result.sources, ["released"])
        // Words take the times they were heard at, in order.
        let starts = result.lines.flatMap(\.words).map(\.start)
        XCTAssertEqual(starts, starts.sorted())
        XCTAssertEqual(result.lines[4].words[0].start, heard[25].start, accuracy: 0.001)
        XCTAssertTrue(LyricsMatch.prefersAssembly(result, over: Self.released, explained: explained(heard)))
        // The output is ordinary word-timed LRC.
        XCTAssertEqual(LyricsParser.parse(result.lrc).map(\.text), sung)
    }

    func testAVerseNoLyricHasStaysAsHeard() {
        let fresh = "brand new words that nobody wrote down yet"
        let heard = Self.sing(Self.v1 + [fresh] + Self.chorus)
        let result = LyricAssembly.assemble(heard: heard, pieces: [Self.released])
        XCTAssertEqual(texts(result).first, Self.v1[0])
        XCTAssertEqual(texts(result).suffix(2), Self.chorus[...])
        let middle = result.lines.filter { $0.origin == .heard }
        XCTAssertEqual(middle.map(\.text).joined(separator: " "), fresh)
        XCTAssertGreaterThan(result.addedShare, 0.2)
        XCTAssertTrue(LyricsMatch.prefersAssembly(result, over: Self.released, explained: explained(heard)))
    }

    func testALineTheRecognizerMissedIsFilledInFromTheLyric() {
        // Silence where "I count the windows…" was sung.
        let heard = Self.sing([Self.v1[0], ""] + Self.chorus, pause: 0.6)
        let result = LyricAssembly.assemble(heard: heard, pieces: [Self.released])
        XCTAssertEqual(texts(result), Self.v1 + Self.chorus)
        XCTAssertEqual(result.lines[1].origin, .filled("released"))
        let filled = result.lines[1].words
        XCTAssertGreaterThan(filled.first!.start, result.lines[0].words.last!.end - 0.001)
        XCTAssertLessThan(filled.last!.end, result.lines[2].words.first!.start + 0.001)
    }

    func testAMisheardLineIsReplacedByTheLineItsNeighboursCallFor() {
        let heard = Self.sing([Self.v1[0], "eye cow the wind ohs", Self.chorus[0]])
        let result = LyricAssembly.assemble(heard: heard, pieces: [Self.released])
        XCTAssertEqual(texts(result), [Self.v1[0], Self.v1[1], Self.chorus[0]])
        XCTAssertEqual(result.onlineShare, 1, accuracy: 0.001)
    }

    func testAShorterVersionLeavesOutWhatWasNeverSungAndIsPreferred() {
        let heard = Self.sing(Self.v1 + Self.chorus)
        let result = LyricAssembly.assemble(heard: heard, pieces: [Self.released])
        XCTAssertEqual(texts(result), Self.v1 + Self.chorus)
        XCTAssertGreaterThan(explained(heard), 0.9, "the whole lyric accounts for everything heard…")
        XCTAssertTrue(LyricsMatch.prefersAssembly(result, over: Self.released, explained: explained(heard)), "…but has verses this version doesn't")
    }

    func testTheSameVersionKeepsTheWholeLyric() {
        var lines = Self.v1 + Self.chorus + Self.v2 + Self.chorus + Self.bridge + Self.chorus
        lines[0] = "streetlight hum along the"                       // misheard
        lines[6] = ""                                               // missed entirely
        let heard = Self.sing(lines)
        let result = LyricAssembly.assemble(heard: heard, pieces: [Self.released])
        XCTAssertFalse(LyricsMatch.prefersAssembly(result, over: Self.released, explained: explained(heard)))
    }

    func testAnotherSongsLyricsAreNotUsed() {
        let other = LyricCandidate(id: "other", source: "LRCLIB", title: "Night Bus", artist: "Someone Else", duration: nil,
                                   text: "Carry me home before the morning\nWe were dancing on the ceiling\nNeon rivers in the sky\nMy heart is on the radio\nTurn it up and let it go\nAll the cities fade away")
        let heard = Self.sing(Self.v1 + [Self.chorus[1]])
        let result = LyricAssembly.assemble(heard: heard, pieces: [other])
        XCTAssertEqual(result.onlineLines, 0, "one shared line doesn't make it this song's lyric")
        XCTAssertEqual(result.lines.flatMap(\.words).count, heard.count)
        XCTAssertFalse(LyricsMatch.prefersAssembly(result, over: nil, explained: nil))
    }

    func testLinesFromSeveralLyricsAreCombinedAndSectionNamesIgnored() {
        let demo = LyricCandidate(id: "demo", source: "From the source", title: "Night Bus (Demo)", artist: "Ines Vale", duration: nil,
                                  text: "Verse 1:\nWaiting at the shelter in the rain\nNobody here knows my name\n(Chorus)\nHold on to the night bus")
        let heard = Self.sing(["waiting at the shelter in the rain", "nobody here knows my name"] + Self.chorus + Self.v2)
        let result = LyricAssembly.assemble(heard: heard, pieces: [Self.released, demo])
        XCTAssertEqual(texts(result), ["Waiting at the shelter in the rain", "Nobody here knows my name"] + Self.chorus + Self.v2)
        XCTAssertEqual(Set(result.sources), ["released", "demo"])
        XCTAssertTrue(LyricAssembly.isLabel("Verse 1:")); XCTAssertTrue(LyricAssembly.isLabel("(Chorus)")); XCTAssertTrue(LyricAssembly.isLabel("[Pre-Chorus]"))
        XCTAssertTrue(LyricAssembly.isLabel("Chorus x2")); XCTAssertTrue(LyricAssembly.isLabel("[Verse 2: Juno Reyes]"))
        XCTAssertFalse(LyricAssembly.isLabel("Hook me up tonight")); XCTAssertFalse(LyricAssembly.isLabel("Bridge over the water"))
    }

    /// A seeded generator, so the noisy transcripts are the same every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
    }

    func testANoisyTranscriptOfAReorderedVersionStillGetsEveryLine() {
        let sung = Self.v2 + Self.chorus + Self.v1 + Self.chorus + Self.bridge + Self.chorus + Self.chorus
        var random = Seeded(state: 7)
        // The recognizer drops words, mishears some and adds a few of its own.
        let noisy = sung.map { line in
            line.split(separator: " ").compactMap { word -> String? in
                let roll = Int.random(in: 0..<100, using: &random)
                return roll < 15 ? nil : roll < 25 ? "uh" : String(word)
            }.joined(separator: " ") + (Int.random(in: 0..<100, using: &random) < 20 ? " yeah" : "")
        }
        let result = LyricAssembly.assemble(heard: Self.sing(noisy), pieces: [Self.released])
        XCTAssertEqual(result.lines.filter { $0.origin != .heard }.map(\.text), sung)
        XCTAssertGreaterThan(result.onlineShare, 0.8)
    }

    func testALongSongWithManyLyricsIsPiecedQuickly() {
        var random = Seeded(state: 11)
        func word() -> String { String((0..<Int.random(in: 2...4, using: &random)).map { _ in ["ba", "ko", "ri", "sen", "tu", "mal", "do", "vi", "ne", "sha", "lo", "gar"].randomElement(using: &random)! }.joined()) }
        let lines = (0..<70).map { _ in (0..<Int.random(in: 5...9, using: &random)).map { _ in word() }.joined(separator: " ") }
        let pieces = (0..<10).map { index in
            LyricCandidate(id: "l\(index)", source: "LRCLIB", title: "Long", artist: "A", duration: nil,
                           text: (lines.shuffled(using: &random).prefix(50) + (0..<20).map { _ in word() + " " + word() + " " + word() + " " + word() }).joined(separator: "\n"))
        }
        let heard = Self.sing(Array(lines.shuffled(using: &random).prefix(90)) + Array(lines.prefix(20)), pause: 0.8)
        XCTAssertGreaterThan(heard.count, 600)
        let clock = ContinuousClock(), began = clock.now
        let result = LyricAssembly.assemble(heard: heard, pieces: pieces)
        for piece in pieces { _ = LyricsMatch.fit(piece, heard: heard) }
        XCTAssertLessThan(clock.now - began, .seconds(2), "scored and pieced on the main thread as results arrive")
        XCTAssertGreaterThan(result.onlineShare, 0.9)
    }

    func testNothingFoundOnlineGivesTheTranscript() {
        let heard = Self.sing(["something only heard here", "", "and a second line"])
        let result = LyricAssembly.assemble(heard: heard, pieces: [])
        XCTAssertEqual(result.lrc, TimedLyricWord.enhancedLRC(heard))
        XCTAssertEqual(result.onlineShare, 0)
        XCTAssertTrue(LyricAssembly.assemble(heard: [], pieces: [Self.released]).lines.isEmpty)
    }

    func testSungAndWrittenSpellingsOfOneWordMatch() {
        for (a, b) in [("gonna", "going"), ("you're", "your"), ("'cause", "because"), ("right", "write"), ("know", "no"), ("til", "until"), ("2", "too"), ("nothin'", "nothing")] {
            XCTAssertGreaterThan(LyricAlignment.similar(a, b), 0, "\(a) / \(b)")
        }
        for (a, b) in [("love", "hate"), ("the", "to"), ("me", "my"), ("in", "on")] {
            XCTAssertLessThan(LyricAlignment.similar(a, b), 0, "\(a) / \(b)")
        }
    }

    // MARK: Saving

    func draft(_ choice: LyricsChoice) -> SongDraft {
        var song = DownloadedSong(file: URL(fileURLWithPath: "/tmp/night-bus.mp3"), source: ScoutTrack(title: "Night Bus", artist: "Ines Vale", album: "", audioURL: "https://x/1"))
        song.duration = 120
        var draft = SongDraft(song: song); draft.lyrics = choice
        return draft
    }
    struct Deaf: AudioListening {
        func words(in file: URL, duration: Double, locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws -> [TimedLyricWord] { [] }
    }

    func testGeneratingUsesTheLyricsFoundWhereTheyWereSung() async throws {
        let heard = Self.sing(Self.chorus + Self.v1)
        let text = try await LyricsMaker.finalize(draft(.generate), locale: Locale(identifier: "en_US"), heard: heard, pieces: [Self.released], listener: Deaf()) { _ in }
        XCTAssertEqual(LyricsParser.parse(text ?? "").map(\.text), Self.chorus + Self.v1)
        XCTAssertTrue(LyricsParser.parse(text ?? "").allSatisfy { !$0.words.isEmpty })
    }

    func testLineTimesFromAVersionOfAnotherLengthDontHoldWordsAway() async throws {
        // The lyric's times are for a version with a 40 s longer intro.
        let lines = Self.v1 + Self.chorus
        let late = lines.enumerated().map { String(format: "[00:%02d.00]", 45 + $0.offset * 3) + $0.element }.joined(separator: "\n")
        let heard = Self.sing(lines)
        let text = try await LyricsMaker.finalize(draft(.text(late, source: "LRCLIB")), locale: Locale(identifier: "en_US"), heard: heard, listener: Deaf()) { _ in }
        let parsed = LyricsParser.parse(text ?? "")
        XCTAssertEqual(parsed.map(\.text), lines)
        XCTAssertEqual(parsed[0].words.first?.start ?? -1, heard[0].start, accuracy: 0.001)
        XCTAssertEqual(parsed[3].words.last?.start ?? -1, heard.last!.start, accuracy: 0.001)
    }
}

@MainActor final class PiecedRecommendationTests: XCTestCase {
    final class NoFetch: SongFetching { func fetch(_ items: [ScoutTrack]) async -> (songs: [DownloadedSong], failures: [String]) { ([], []) } }
    struct NoCatalog: CatalogSearching {
        func songs(_ term: String) async -> [CatalogMatch] { [] }
        func albums(_ term: String) async -> [CatalogMatch] { [] }
        func artists(_ term: String) async -> [String] { [] }
    }
    struct Released: LyricsSearching {
        func candidates(title: String, artists: [String], duration: Double) async throws -> [LyricCandidate] { [LyricAssemblyTests.released] }
    }
    /// A leak: second verse first, then the chorus twice, no bridge.
    struct HearsLeak: AudioListening {
        func words(in file: URL, duration: Double, locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws -> [TimedLyricWord] {
            LyricAssemblyTests.sing(LyricAssemblyTests.v2 + LyricAssemblyTests.chorus + LyricAssemblyTests.v1 + LyricAssemblyTests.chorus)
        }
    }
    func testALeakSungInAnotherOrderIsRecommendedPiecedTogether() async throws {
        let flow = ScoutFlow(mode: .song, fetcher: NoFetch(), catalog: NoCatalog(), lyrics: Released(), listener: HearsLeak())
        flow.begin(with: [DownloadedSong(file: URL(fileURLWithPath: "/tmp/leak.mp3"), source: ScoutTrack(title: "Night Bus", artist: "Ines Vale", album: "", audioURL: "https://x/leak"))])
        let id = flow.drafts[0].id
        for _ in 0..<100 {
            if case .recommended(let best, _) = flow.recommendation(id), best.id == "generated" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .recommended(let best, let share) = flow.recommendation(id) else { return XCTFail("no recommendation") }
        XCTAssertEqual(best.id, "generated")
        XCTAssertEqual(best.source, "Pieced from your audio and LRCLIB")
        XCTAssertGreaterThan(share, 0.9)
        XCTAssertEqual(LyricsParser.parse(best.text).map(\.text), LyricAssemblyTests.v2 + LyricAssemblyTests.chorus + LyricAssemblyTests.v1 + LyricAssemblyTests.chorus)
        XCTAssertEqual(flow.drafts[0].lyrics, .text(best.text, source: best.source), "pre-selected")
    }
}
