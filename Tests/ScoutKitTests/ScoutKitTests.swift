import XCTest
import AVFoundation
@testable import ScoutKit

final class SuggestionTests: XCTestCase {
    func testArtistsSplitOnCreditsButKeepNamesWhole() {
        XCTAssertEqual(Suggestions.splitArtists("Ines Vale feat. Juno Reyes & Low Orchard"), ["Ines Vale", "Juno Reyes", "Low Orchard"])
        XCTAssertEqual(Suggestions.splitArtists("A, B x C"), ["A", "B", "C"])
        XCTAssertEqual(Suggestions.splitArtists("Salt and Cedar"), ["Salt and Cedar"])
        XCTAssertEqual(Suggestions.splitArtists("A & a"), ["A"])
    }
    func testNameVariantsOfferTheRawNameAndCleanerOnes() {
        let options = Suggestions.nameVariants("03 - Night Bus (feat. Juno Reyes) [CDQ]")
        XCTAssertEqual(options.first, "03 - Night Bus (feat. Juno Reyes) [CDQ]")
        XCTAssertTrue(options.contains("Night Bus (feat. Juno Reyes)"))
        XCTAssertTrue(options.contains("Night Bus"))
        XCTAssertEqual(Set(options).count, options.count)
        XCTAssertEqual(Suggestions.featured(in: "Night Bus (feat. Juno Reyes & Low Orchard)"), ["Juno Reyes", "Low Orchard"])
    }
    func testOptionsCombineSourceTagsAndCatalogWithoutDuplicates() {
        var song = DownloadedSong(file: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mp3"), source: ScoutTrack(title: "Night Bus [CDQ]", artist: "Ines Vale", album: "X", audioURL: "https://x"))
        song.taggedArtist = "Ines Vale, Juno Reyes"
        let matches = [CatalogMatch(title: "Night Bus", artists: ["Ines Vale", "Low Orchard"], album: "Y", coverURL: URL(string: "https://a/1.jpg"), source: "T")]
        let names = Suggestions.nameOptions(for: song, matches: matches)
        XCTAssertEqual(names.first, "Night Bus [CDQ]"); XCTAssertEqual(names.filter { $0 == "Night Bus" }.count, 1)
        XCTAssertFalse(names.contains { UUID(uuidString: $0) != nil }, "staging file names are never offered")
        XCTAssertEqual(Suggestions.artistOptions(for: song, title: "Night Bus", matches: matches), ["Ines Vale", "Juno Reyes", "Low Orchard"])
        XCTAssertEqual(Suggestions.coverOptions(for: song, matches: matches + matches).count, 1)
    }
}

final class SpotiPWLyricsTests: XCTestCase {
    func testURIEncodingMatchesSpotiPW() {
        XCTAssertEqual(SpotiPWLyrics.encode("Ines Vale & Juno-Reyes_~."), "Ines+Vale+%26+Juno-Reyes_~.")
        XCTAssertEqual(SpotiPWLyrics.encode("Beyoncé"), "Beyonc%C3%A9")
        XCTAssertEqual(SpotiPWLyrics.encode(String(repeating: "a", count: 250)).count, 200, "only the first 200 bytes are used")
        let uri = SpotiPWLyrics.localURI(artist: "Ines Vale, Juno Reyes", album: "The Quiet Hours", title: "Night Bus", seconds: 183)
        XCTAssertEqual(uri, "spotify:local:Ines+Vale%2C+Juno+Reyes:The+Quiet+Hours:Night+Bus:183")
        // SHA-256 of the URI, lowercase hex (computed independently with shasum).
        XCTAssertEqual(SpotiPWLyrics.key("spotify:local:a:b:c:1"), "15f20b3e5a6a91590c3b5d1ddec2dc08a8c606b172cb605a625ca0162b001160")
        XCTAssertEqual(SpotiPWLyrics.key("spotify:track:abc"), "spotify:track:abc")
    }
    func testWritesEveryLikelyLengthAndReplacesOtherFormats() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let plainKey = SpotiPWLyrics.key(SpotiPWLyrics.localURI(artist: "A", album: "B", title: "C", seconds: 100))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "old".write(to: folder.appendingPathComponent(plainKey + ".txt"), atomically: true, encoding: .utf8)
        let files = try SpotiPWLyrics.write("[00:01.00]Hi", artist: "A", album: "B", title: "C", duration: 100.7, into: folder)
        XCTAssertEqual(files.count, 3); XCTAssertTrue(files.allSatisfy { $0.hasSuffix(".lrc") })
        XCTAssertTrue(files.contains(plainKey + ".lrc"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(plainKey + ".txt").path))
        XCTAssertEqual(SpotiPWLyrics.fileExtension(for: "just words"), "txt")
    }
}

final class LyricsQueryTests: XCTestCase {
    func testAsksWithEachArtistCleanedNameAndTitleAlone() {
        let queries = LyricsSearch.queries(title: "Night Bus [CDQ]", artists: ["Ines Vale", "Unknown artist", "Juno Reyes"])
        XCTAssertTrue(queries.contains(["track_name": "Night Bus", "artist_name": "Ines Vale"]))
        XCTAssertTrue(queries.contains(["track_name": "Night Bus [CDQ]", "artist_name": "Juno Reyes"]))
        XCTAssertTrue(queries.contains(["track_name": "Night Bus"]))
        XCTAssertFalse(queries.contains { $0["artist_name"] == "Unknown artist" })
        XCTAssertLessThanOrEqual(queries.count, 8)
    }
}

final class LyricsMatchTests: XCTestCase {
    let heard = "i can feel it coming in the air tonight oh lord".split(separator: " ").enumerated().map { TimedLyricWord(start: Double($0.offset), end: Double($0.offset) + 0.5, text: String($0.element)) }
    func candidate(_ id: String, _ text: String) -> LyricCandidate { .init(id: id, source: "T", title: "T", artist: "A", duration: nil, text: text) }
    func testTheLyricsThatWereSungScoreHighAndOthersLow() {
        let right = candidate("right", "[00:01.00]I can feel it coming in the air tonight\n[00:05.00]Oh Lord")
        let wrong = candidate("wrong", "[00:01.00]Paper boats are drifting down the river\n[00:05.00]Slowly home")
        let partial = candidate("partial", "Oh Lord")
        XCTAssertGreaterThan(LyricsMatch.score(right, heard: heard), 0.8)
        XCTAssertLessThan(LyricsMatch.score(wrong, heard: heard), LyricsMatch.threshold)
        XCTAssertLessThan(LyricsMatch.score(partial, heard: heard), LyricsMatch.score(right, heard: heard), "a fragment is not a full match")
        let scores = Dictionary(uniqueKeysWithValues: [right, wrong, partial].map { ($0.id, LyricsMatch.score($0, heard: heard)) })
        XCTAssertEqual(LyricsMatch.best([wrong, partial, right], scores: scores)?.id, "right")
        XCTAssertNil(LyricsMatch.best([wrong], scores: scores), "nothing above the threshold means none match")
    }
    func testTiesGoToTheBetterTimedLyrics() {
        let plain = candidate("plain", "I can feel it coming in the air tonight oh Lord")
        let timed = candidate("timed", "[00:01.00]I can feel it coming in the air tonight oh Lord")
        XCTAssertEqual(LyricsMatch.best([plain, timed], scores: ["plain": 0.9, "timed": 0.88])?.id, "timed")
    }
}

final class LyricsRankingTests: XCTestCase {
    func testClosestLengthAndTitleComeFirstAndEveryMatchIsKept() {
        let far = LyricCandidate(id: "far", source: "L", title: "Night Bus", artist: "A", duration: 300, text: "[00:01.00]x")
        let near = LyricCandidate(id: "near", source: "L", title: "Night Bus", artist: "A", duration: 181, text: "plain")
        let other = LyricCandidate(id: "other", source: "L", title: "Different", artist: "A", duration: 180, text: "[00:01.00]y")
        let ranked = LyricsSearch.ranked([far, other, near], title: "Night Bus", duration: 180)
        XCTAssertEqual(ranked.count, 3)
        XCTAssertEqual(ranked.first?.id, "near")
        XCTAssertEqual(near.kind, "Plain text"); XCTAssertEqual(far.kind, "Line-timed")
    }
}

@MainActor final class SaveTests: XCTestCase {
    var work: URL!
    override func setUp() async throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work) }
    func tone(_ name: String) throws -> URL {
        let url = work.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!; buffer.frameLength = 4410
        for i in 0..<4410 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.1) * 0.05 }
        try file.write(from: buffer)
        return url
    }
    func testSavingTagsTheAudioWritesAnLRCAndRecordsTheSong() async throws {
        let library = ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support"))
        var draft = SongDraft(song: await DownloadedSong.make(file: try tone("in.wav"), source: nil, artwork: nil))
        draft.title = "Night Bus"; draft.artists = ["Ines Vale", "Juno Reyes"]; draft.album = "The Quiet Hours"
        let lyrics = "[00:00.10]First line"
        let saved = try await library.save(draft, lyrics: lyrics, lyricsSource: "LRCLIB")
        let file = library.fileURL(saved)
        XCTAssertEqual(file.lastPathComponent, "Ines Vale, Juno Reyes - Night Bus.m4a")
        XCTAssertEqual(try String(contentsOf: file.deletingPathExtension().appendingPathExtension("lrc"), encoding: .utf8), lyrics)
        let tagged = await DownloadedSong.make(file: file, source: nil, artwork: nil)
        XCTAssertEqual(tagged.taggedTitle, "Night Bus"); XCTAssertEqual(tagged.taggedArtist, "Ines Vale, Juno Reyes"); XCTAssertEqual(tagged.taggedAlbum, "The Quiet Hours")
        XCTAssertEqual(tagged.taggedLyrics, lyrics)
        // spoti.pw's own lyrics folder gets the file under this song's URI key.
        let files = try XCTUnwrap(saved.spotiLyricsFiles)
        XCTAssertFalse(files.isEmpty)
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: library.spotiLyricsFolder.appendingPathComponent($0).path) })
        XCTAssertEqual(library.spotiLyricsFolder.path, work.appendingPathComponent("spoti.pw/Lyrics").path)
        // A second save with the same name does not overwrite the first.
        let again = try await library.save(SongDraft(song: await DownloadedSong.make(file: try tone("in2.wav"), source: nil, artwork: nil)).with { $0.title = "Night Bus"; $0.artists = ["Ines Vale", "Juno Reyes"] }, lyrics: nil, lyricsSource: nil)
        XCTAssertNotEqual(again.filename, saved.filename)
        XCTAssertEqual(ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support")).songs.count, 2)
    }
    func testMP3KeepsItsAudioAndGetsAnID3v24Tag() throws {
        let source = work.appendingPathComponent("in.mp3"), output = work.appendingPathComponent("out.mp3")
        let audio = Data([0xFF, 0xFB, 0x90, 0x64] + Array(repeating: UInt8(7), count: 400))
        try (Data("ID3".utf8) + Data([3, 0, 0, 0, 0, 0, 10]) + Data(repeating: 0, count: 10) + audio).write(to: source)
        try TagWriter.writeMP3(.init(title: "T", artist: "A, B", album: "Al", albumArtist: "A", trackNumber: 2, artwork: nil, lyrics: "la"), from: source, to: output)
        let data = try Data(contentsOf: output)
        XCTAssertEqual(Array(data.prefix(4)), [0x49, 0x44, 0x33, 4])
        XCTAssertTrue(data.range(of: Data("TPE1".utf8)) != nil && data.range(of: Data("USLT".utf8)) != nil)
        XCTAssertEqual(data.suffix(audio.count), audio, "audio bytes after the old tag are copied unchanged")
    }
    func testAlbumBecomesAPendingPlaylistPlanWithItsCover() async throws {
        let library = ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support"))
        let song = try await library.save(SongDraft(song: await DownloadedSong.make(file: try tone("a.wav"), source: nil, artwork: nil)).with { $0.title = "One"; $0.artists = ["A"] }, lyrics: nil, lyricsSource: nil)
        let plan = try await library.plan(album: "Album", artists: ["A"], cover: Data([0xFF, 0xD8, 0xFF]), songs: [song])
        XCTAssertEqual(plan.status, .pending); XCTAssertEqual(plan.songIDs, [song.id]); XCTAssertNil(plan.playlistURI)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.supportFolder.appendingPathComponent("Covers").appendingPathComponent(plan.coverFilename!).path))
        XCTAssertEqual(ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support")).playlists, [plan])
    }
}

@MainActor final class FlowTests: XCTestCase {
    final class NoFetch: SongFetching { func fetch(_ items: [ScoutTrack]) async -> (songs: [DownloadedSong], failures: [String]) { ([], []) } }
    struct NoCatalog: CatalogSearching {
        func songs(_ term: String) async -> [CatalogMatch] { [] }
        func albums(_ term: String) async -> [CatalogMatch] { [] }
        func artists(_ term: String) async -> [String] { [] }
    }
    struct NoLyrics: LyricsSearching { func candidates(title: String, artists: [String], duration: Double) async -> [LyricCandidate] { [] } }
    struct Deaf: AudioListening {
        func words(in file: URL, duration: Double, locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws -> [TimedLyricWord] { [] }
    }
    func songs(_ count: Int) -> [DownloadedSong] {
        (0..<count).map { DownloadedSong(file: URL(fileURLWithPath: "/tmp/\($0).mp3"), source: ScoutTrack(title: "Song \($0)", artist: "Ines Vale", album: "Album", audioURL: "https://x/\($0)")) }
    }
    func testAlbumStepsGoPerSongInTheRequestedOrderAndAskOnceAboutMissingLyrics() {
        let flow = ScoutFlow(mode: .album, fetcher: NoFetch(), catalog: NoCatalog(), lyrics: NoLyrics(), listener: Deaf())
        flow.begin(with: songs(2))
        XCTAssertEqual(flow.path, [.names]); XCTAssertEqual(flow.albumName, "Album")
        flow.next(); XCTAssertEqual(flow.page, 1); XCTAssertEqual(flow.path, [.names])
        flow.next(); XCTAssertEqual(flow.path, [.names, .lyrics]); XCTAssertEqual(flow.page, 0)
        flow.drafts[0].lyrics = .text("x", source: "s")
        flow.next(); flow.next()
        XCTAssertTrue(flow.askGenerate); XCTAssertEqual(flow.missingLyrics, 1)
        flow.answerGenerate(true)
        XCTAssertEqual(flow.drafts[1].lyrics, .generate); XCTAssertEqual(flow.path.last, .artists)
        flow.back(); XCTAssertEqual(flow.path.last, .lyrics); XCTAssertEqual(flow.page, 1)
    }
    struct HearsChorus: AudioListening {
        func words(in file: URL, duration: Double, locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws -> [TimedLyricWord] {
            "oh lord oh lord".split(separator: " ").enumerated().map { TimedLyricWord(start: Double($0.offset), end: Double($0.offset) + 0.5, text: String($0.element)) }
        }
    }
    struct Found: LyricsSearching {
        func candidates(title: String, artists: [String], duration: Double) async throws -> [LyricCandidate] {
            [.init(id: "x", source: "L", title: title, artist: "A", duration: nil, text: "[00:01.00]Oh Lord oh Lord")]
        }
    }
    func testListeningRecommendsAndPreselectsButNeverOverridesTheUser() async throws {
        let flow = ScoutFlow(mode: .album, fetcher: NoFetch(), catalog: NoCatalog(), lyrics: Found(), listener: HearsChorus())
        flow.begin(with: songs(2))
        for _ in 0..<50 where flow.recommendation(flow.drafts[1].id) == .waiting { try await Task.sleep(for: .milliseconds(50)) }
        guard case .recommended(let best, let score) = flow.recommendation(flow.drafts[0].id) else { return XCTFail("no recommendation") }
        XCTAssertEqual(best.id, "x"); XCTAssertGreaterThan(score, 0.9)
        XCTAssertEqual(flow.drafts[0].lyrics, .text(best.text, source: "L"))
        XCTAssertTrue(flow.lyricOptions[flow.drafts[0].id]?.contains { $0.id == "generated" } ?? false)
        // A user's own choice survives a later rescore.
        flow.choose(.none, for: flow.drafts[1].id)
        await flow.loadLyrics(for: flow.drafts[1].id)
        XCTAssertEqual(flow.drafts[1].lyrics, LyricsChoice.none)
    }
    /// Song 0's lyrics are online and sung; song 1 has none online, song 2 only wrong ones.
    struct SomeLyrics: LyricsSearching {
        func candidates(title: String, artists: [String], duration: Double) async throws -> [LyricCandidate] {
            switch title {
            case "Song 0": return [.init(id: "right", source: "LRCLIB", title: title, artist: "A", duration: nil, text: "[00:01.00]I can feel it coming in the air tonight\n[00:05.00]Oh Lord")]
            case "Song 2": return [.init(id: "wrong", source: "LRCLIB", title: title, artist: "A", duration: nil, text: "Paper boats are drifting down the river slowly home")]
            default: return []
            }
        }
    }
    struct Hears: AudioListening {
        func words(in file: URL, duration: Double, locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws -> [TimedLyricWord] {
            "i can feel it coming in the air tonight oh lord".split(separator: " ").enumerated().map { TimedLyricWord(start: Double($0.offset), end: Double($0.offset) + 0.5, text: String($0.element)) }
        }
    }
    func testQuickSetupUsesRecommendationsAndGeneratesTheRestButKeepsUserChoices() async throws {
        let flow = ScoutFlow(mode: .album, fetcher: NoFetch(), catalog: NoCatalog(), lyrics: SomeLyrics(), listener: Hears())
        flow.begin(with: songs(4))
        flow.choose(.none, for: flow.drafts[3].id)          // the user's own choice stays
        flow.next(); flow.next(); flow.next(); flow.next()   // names
        XCTAssertEqual(flow.path.last, .lyrics)
        flow.quickSetup()
        XCTAssertEqual(flow.path.last, .artists, "quick setup moves past every lyrics page without the prompt")
        XCTAssertFalse(flow.askGenerate)
        for id in flow.drafts.map(\.id) { await flow.settleQuick(id) }
        XCTAssertEqual(flow.drafts[0].lyrics, .text("[00:01.00]I can feel it coming in the air tonight\n[00:05.00]Oh Lord", source: "LRCLIB"))
        XCTAssertEqual(flow.drafts[1].lyrics, .generate)
        XCTAssertEqual(flow.drafts[2].lyrics, .generate, "lyrics that don't match what was heard aren't used")
        XCTAssertEqual(flow.drafts[3].lyrics, LyricsChoice.none)
    }
    func testSongStepsAreNameArtistsCoverLyrics() {
        let flow = ScoutFlow(mode: .song, fetcher: NoFetch(), catalog: NoCatalog(), lyrics: NoLyrics(), listener: Deaf())
        flow.begin(with: songs(1))
        flow.next(); flow.next(); flow.next()
        XCTAssertEqual(flow.path, [.names, .artists, .cover, .lyrics])
        // The automatic prompt sets the choice without leaving the step.
        flow.promptForMissing(); flow.answerGenerate(false)
        XCTAssertEqual(flow.path.last, .lyrics); XCTAssertEqual(flow.drafts[0].lyrics, LyricsChoice.none)
    }
}

extension SongDraft {
    func with(_ change: (inout SongDraft) -> Void) -> SongDraft { var copy = self; change(&copy); return copy }
}
