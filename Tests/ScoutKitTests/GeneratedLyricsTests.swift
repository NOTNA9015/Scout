import XCTest
@testable import ScoutKit

/// The generated lyrics, every song's default: plain and line-timed lyrics timed word by word,
/// unheard lines placed at their lyric's own timing, a mashup pieced from each part's own
/// lyrics, and nothing shown twice.
final class GeneratedLyricsTests: XCTestCase {
    typealias Night = LyricAssemblyTests
    static let boats = ["Paper boats are drifting down the river", "Carry all the letters I never sent", "Rain on the water", "Fold another one and let it go"]
    static let paperBoats = LyricCandidate(id: "boats", source: "LRCLIB", title: "Paper Boats", artist: "Low Orchard", duration: 180, text: boats.joined(separator: "\n"))

    /// Each line's words 0.4 s apart from the time given, as the recognizer writes them.
    static func sing(_ lines: [String], at starts: [Double]) -> [TimedLyricWord] {
        zip(lines, starts).flatMap { line, start in
            line.split(separator: " ").enumerated().map { index, word in
                TimedLyricWord(start: start + Double(index) * 0.4, end: start + Double(index) * 0.4 + 0.32, text: word.lowercased().filter { $0.isLetter || $0 == "'" })
            }
        }
    }

    func testAWallOfTextIsCutIntoSungLinesAndTimedWordByWord() {
        let lines = Night.v1 + Night.chorus + Night.v2
        let wall = lines.joined(separator: " ")
        XCTAssertEqual(LyricAssembly.sungLines(wall), [Night.v1.joined(separator: " ")] + Night.chorus + Night.v2,
                       "cut where a line starts with a capital; \"I\" isn't a new line")
        let heard = Night.sing(lines)
        let made = LyricsMaker.generate(heard: heard, pieces: [.init(id: "wall", source: "LRCLIB", title: "Night Bus", artist: "Ines Vale", duration: nil, text: wall)])
        let parsed = LyricsParser.parse(made.lrc)
        XCTAssertEqual(parsed.map(\.text).joined(separator: " "), wall, "every word kept as written")
        XCTAssertEqual(parsed.count, 5)
        XCTAssertTrue(parsed.allSatisfy { !$0.words.isEmpty })
        XCTAssertEqual(parsed.flatMap(\.words)[13].text, "Hold")
        XCTAssertEqual(parsed.flatMap(\.words)[13].start, heard[13].start, accuracy: 0.01, "timed where it was sung")
    }

    func testLongLinesAndSectionNamesInsideTheText() {
        XCTAssertEqual(LyricAssembly.sungLines("(Chorus) Hold on to the night bus [Verse 2: Juno Reyes] Paper tickets"), ["Hold on to the night bus", "Paper tickets"])
        XCTAssertEqual(LyricAssembly.sungLines("(Hook me up) tonight"), ["(Hook me up) tonight"], "words in brackets that aren't a section name stay")
        let rap = "I pull up in the Benz with my dawgs and we ride all night long"
        XCTAssertEqual(LyricAssembly.sungLines(rap), [rap], "a long line stays whole, a name doesn't start a line")
        let long = "we kept on running through the night and never looked back once, the city lights were fading out behind us all the way home"
        XCTAssertEqual(LyricAssembly.sungLines(long), ["we kept on running through the night and never looked back once,", "the city lights were fading out behind us all the way home"])
    }

    func testALineTimedLyricSungAsWrittenKeepsEveryLineWithEveryWordTimed() {
        let sung = Night.v1 + Night.chorus + Night.v2 + Night.chorus + Night.bridge + Night.chorus
        var heardLines = sung
        heardLines[4] = ""                                       // "Paper tickets…" too quiet to hear
        let made = LyricsMaker.generate(heard: Night.sing(heardLines), pieces: [Night.released])
        XCTAssertEqual(made.whole?.id, "released")
        XCTAssertEqual(made.source, "LRCLIB, timed to your audio")
        let parsed = LyricsParser.parse(made.lrc)
        XCTAssertEqual(parsed.map(\.text), sung, "the line nobody heard is kept too")
        XCTAssertTrue(parsed.allSatisfy { !$0.words.isEmpty })
        let starts = parsed.flatMap(\.words).map(\.start)
        XCTAssertEqual(starts, starts.sorted())
    }

    func testLinesTheRecognizerMissedAreSyncedFromTheLyricsOwnTiming() {
        let written = ["Streetlights hum along the avenue", "I count the windows till I find you", "Hold on to the night bus", "Carry me home before the morning",
                       "Paper tickets folded in my pocket", "Every stop a little closer to you", "Don't let the driver turn around", "Wake me when we reach the river",
                       "Neon fading into gray", "Hold me till the doors give way"]
        // An instrumental break in the lyric between lines 4 and 5.
        let times = [10.0, 14, 18, 22, 25, 33, 36, 40, 44, 48]
        let text = zip(times, written).map { String(format: "[00:%05.2f]", $0) + $1 }.joined(separator: "\n")
        let lyric = LyricCandidate(id: "timed", source: "LRCLIB", title: "Night Bus", artist: "Ines Vale", duration: 200, text: text)
        // This version: a 20 s longer intro, lines 3–6 too quiet to hear, and a verse of its own at the end.
        let sungLines = [0, 1, 2, 7, 8, 9]
        let heard = Self.sing(sungLines.map { written[$0] }, at: sungLines.map { times[$0] + 20 })
            + Self.sing(["brand new words that nobody wrote down yet", "and another line only this version has"], at: [74, 79])
        let result = LyricAssembly.assemble(heard: heard, pieces: [lyric])
        XCTAssertEqual(result.lines.filter { $0.origin != .heard }.map(\.text), written)
        for k in 3...6 {
            guard let line = result.lines.first(where: { $0.text == written[k] }) else { return XCTFail("line \(k) missing") }
            XCTAssertEqual(line.origin, .filled("timed"))
            XCTAssertEqual(line.words[0].start, times[k] + 20, accuracy: 0.05, "line \(k) at the lyric's time, moved to this version")
        }
        XCTAssertNil(LyricsMaker.generate(heard: heard, pieces: [lyric]).whole, "a verse of its own: pieced, not the lyric whole")
    }

    func testAMashupTakesEachPartFromItsOwnSongsLyrics() {
        let sung = Night.v1 + Night.chorus + Self.boats + Night.chorus
        let heard = Night.sing(sung)
        // By its name only Night Bus is found: the Paper Boats part is left as heard, and looked for.
        let first = LyricsMaker.generate(heard: heard, pieces: [Night.released])
        XCTAssertNil(first.whole)
        let passages = LyricParts.passages(first.assembly)
        XCTAssertEqual(passages.count, 1)
        XCTAssertEqual(passages.first?.count, Self.boats.joined(separator: " ").split(separator: " ").count)
        XCTAssertTrue(LyricParts.phrases(passages, heard: heard).contains("paper boats are"))
        let lookalike = LyricCandidate(id: "other", source: "LRCLIB", title: "Paper Planes", artist: "Someone Else", duration: nil,
                                       text: "Flying high above the town\nNever coming down\nPaper planes and paper hearts\nRain on the water tonight")
        XCTAssertEqual(LyricParts.vet([lookalike, Self.paperBoats], passages: passages).map(\.id), ["boats"], "one shared line isn't that song")
        let made = LyricsMaker.generate(heard: heard, pieces: [Night.released], parts: [Self.paperBoats])
        XCTAssertEqual(made.assembly.lines.map(\.text), sung)
        XCTAssertTrue(made.assembly.lines.allSatisfy { $0.origin != .heard })
        XCTAssertEqual(Set(made.assembly.sources), ["released", "boats"])
        XCTAssertEqual(made.lrc, made.assembly.lrc)
    }

    func testWordsHeardTwiceShowOnce() {
        // The first line echoed straight after it, and the end of the chorus sung again as an ad-lib.
        let heard = Night.sing([Night.v1[0], "streetlights hum along", Night.v1[1], Night.chorus[0], Night.chorus[1], "before the morning"])
        let result = LyricAssembly.assemble(heard: heard, pieces: [Night.released])
        XCTAssertEqual(result.lines.map(\.text), Night.v1 + Night.chorus)
        XCTAssertEqual(result.onlineShare, 1, accuracy: 0.001, "the echoes belong to the lines they repeat")
        // A line the lyric itself sings twice in a row is kept twice.
        let twice = LyricCandidate(id: "twice", source: "LRCLIB", title: "Night Bus", artist: "Ines Vale", duration: nil,
                                   text: (Night.v1 + [Night.chorus[0], Night.chorus[0]]).joined(separator: "\n"))
        XCTAssertEqual(LyricAssembly.assemble(heard: Night.sing(Night.v1 + [Night.chorus[0], Night.chorus[0]]), pieces: [twice]).lines.map(\.text),
                       Night.v1 + [Night.chorus[0], Night.chorus[0]])
    }

    func testAMashupsTitleNamesItsParts() {
        XCTAssertEqual(LyricParts.titleParts("Night Bus / Paper Boats"), ["Night Bus", "Paper Boats"])
        XCTAssertEqual(LyricParts.titleParts("Night Bus x Paper Boats (Mashup)"), ["Night Bus", "Paper Boats"])
        XCTAssertEqual(LyricParts.titleParts("Night Bus (Paper Boats Mashup)"), ["Night Bus", "Paper Boats"])
        XCTAssertEqual(LyricParts.titleParts("Medley: Night Bus, Paper Boats & Low Tide"), ["Night Bus", "Paper Boats", "Low Tide"])
        XCTAssertEqual(LyricParts.titleParts("Love & War"), [])
        XCTAssertEqual(LyricParts.titleParts("Night Bus (feat. Juno Reyes)"), [])
        XCTAssertEqual(LyricParts.titleParts("Night Bus (Remix)"), [])
        let queries = LyricsSearch.partQueries(title: "Night Bus / Paper Boats", artists: ["Ines Vale"], phrases: ["hold on"])
        XCTAssertEqual(queries.prefix(2), [["track_name": "Night Bus", "artist_name": "Ines Vale"], ["track_name": "Night Bus"]])
        XCTAssertTrue(queries.contains(["track_name": "hold on"]) && queries.contains(["q": "Ines Vale"]))
    }

    func testNothingHeardFallsBackToTheLyricsThatCameWithTheSongOrMatchItsLength() async throws {
        struct Deaf: AudioListening {
            func words(in file: URL, duration: Double, locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws -> [TimedLyricWord] {
                throw ScoutError.message("No speech model")
            }
        }
        var song = DownloadedSong(file: URL(fileURLWithPath: "/tmp/night-bus.mp3"), source: ScoutTrack(title: "Night Bus", artist: "Ines Vale", album: "", audioURL: "https://x/1"))
        song.duration = 200
        var draft = SongDraft(song: song); draft.lyrics = .generate
        let other = LyricCandidate(id: "o", source: "LRCLIB", title: "Night Bus", artist: "Ines Vale", duration: 150, text: "Another version")
        let made = try await LyricsMaker.finalize(draft, locale: Locale(identifier: "en_US"), heard: nil, pieces: [other, Night.released], listener: Deaf()) { _ in }
        XCTAssertEqual(made, LyricsMaker.Made(text: Night.released.text, source: "LRCLIB"), "the lyric of this length, not the other version")
        let none = try await LyricsMaker.finalize(draft, locale: Locale(identifier: "en_US"), heard: [], pieces: [other], listener: Deaf()) { _ in }
        XCTAssertNil(none, "an instrumental is saved without lyrics, not refused")
    }
}

/// The parts of a song searched for once it was heard, and used in its generated lyrics.
@MainActor final class PartsSearchTests: XCTestCase {
    struct Search: LyricsSearching {
        func candidates(title: String, artists: [String], duration: Double) async throws -> [LyricCandidate] { [LyricAssemblyTests.released] }
        func parts(title: String, artists: [String], phrases: [String]) async -> [LyricCandidate] {
            [GeneratedLyricsTests.paperBoats, .init(id: "noise", source: "LRCLIB", title: "Elsewhere", artist: "X", duration: nil, text: "Nothing like this song\nAt all")]
        }
    }
    struct HearsMashup: AudioListening {
        func words(in file: URL, duration: Double, locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws -> [TimedLyricWord] {
            LyricAssemblyTests.sing(LyricAssemblyTests.v1 + LyricAssemblyTests.chorus + GeneratedLyricsTests.boats + LyricAssemblyTests.chorus)
        }
    }
    func testAMashupsOtherSongIsFoundAndPiecedIn() async throws {
        let flow = ScoutFlow(mode: .song, fetcher: PiecedRecommendationTests.NoFetch(), catalog: PiecedRecommendationTests.NoCatalog(), lyrics: Search(), listener: HearsMashup())
        flow.begin(with: [DownloadedSong(file: URL(fileURLWithPath: "/tmp/mashup.mp3"), source: ScoutTrack(title: "Night Bus", artist: "Ines Vale", album: "", audioURL: "https://x/m"))])
        let id = flow.drafts[0].id
        for _ in 0..<100 where flow.parts[id] == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(flow.parts[id]?.map(\.id), ["boats"], "only the lyric really sung")
        await flow.settle(id)
        guard case .recommended(let pick, let share) = flow.recommendation(id) else { return XCTFail("no recommendation") }
        XCTAssertEqual(pick.id, "generated"); XCTAssertGreaterThan(share, 0.95)
        XCTAssertEqual(LyricsParser.parse(pick.text).map(\.text), LyricAssemblyTests.v1 + LyricAssemblyTests.chorus + GeneratedLyricsTests.boats + LyricAssemblyTests.chorus)
        XCTAssertEqual(flow.drafts[0].lyrics, .generate)
    }
}
