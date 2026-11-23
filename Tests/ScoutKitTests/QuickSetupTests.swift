import XCTest
import AVFoundation
@testable import ScoutKit

@MainActor final class QuickSetupTests: XCTestCase {
    var work: URL!
    override func setUp() async throws { work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work) }

    final class NoFetch: SongFetching { func fetch(_ items: [ScoutTrack]) async -> (songs: [DownloadedSong], failures: [String]) { ([], []) } }
    struct Catalog: CatalogSearching {
        func songs(_ term: String) async -> [CatalogMatch] {
            term.lowercased().contains("night bus") ? [CatalogMatch(title: "Night bus", artists: ["Ines Vale"], album: "The Quiet Hours", coverURL: nil, source: "Fixture")] : []
        }
        func albums(_ term: String) async -> [CatalogMatch] { [] }
        func artists(_ term: String) async -> [String] { [] }
    }
    struct Lyrics: LyricsSearching {
        func candidates(title: String, artists: [String], duration: Double) async throws -> [LyricCandidate] {
            title == "Night bus" || title == "Night Bus"
                ? [.init(id: "right", source: "LRCLIB", title: title, artist: "A", duration: nil, text: "[00:01.00]I can feel it coming in the air tonight\n[00:05.00]Oh Lord")] : []
        }
    }
    struct Hears: AudioListening {
        func words(in file: URL, duration: Double, locale: Locale, progress: @escaping @Sendable (String) -> Void) async throws -> [TimedLyricWord] {
            "i can feel it coming in the air tonight oh lord".split(separator: " ").enumerated().map { TimedLyricWord(start: Double($0.offset), end: Double($0.offset) + 0.5, text: String($0.element)) }
        }
    }
    func song(_ title: String, artist: String) async throws -> DownloadedSong {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let url = work.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!; buffer.frameLength = 16000
        try file.write(from: buffer)
        return await DownloadedSong.make(file: url, source: ScoutTrack(title: title, artist: artist, album: "", audioURL: "https://x/\(title)"), artwork: nil)
    }

    func testQuickSetupEverythingCleansNamesFindsLyricsAndImportsAlbum() async throws {
        let library = ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support"))
        let flow = ScoutFlow(mode: .album, fetcher: NoFetch(), catalog: Catalog(), lyrics: Lyrics(), library: library, listener: Hears())
        flow.begin(with: [try await song("01 - Night Bus (feat. Juno Reyes) [CDQ]", artist: "Ines Vale"),
                          try await song("Paper Boats (Leak)", artist: "Ines Vale & Low Orchard")])
        flow.quickSetupEverything()
        for _ in 0..<200 where flow.current != .done { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(flow.current, .done, flow.failures.joined())
        XCTAssertEqual(flow.saved.map(\.title), ["Night bus", "Paper Boats"], "tags and features gone, the catalog's spelling used")
        XCTAssertEqual(flow.saved[0].artists, ["Ines Vale", "Juno Reyes"])
        XCTAssertEqual(flow.saved[1].artists, ["Ines Vale", "Low Orchard"])
        XCTAssertEqual(flow.saved[0].lyricsSource, "LRCLIB, timed to your audio", "sung as the lyric found is written")
        XCTAssertEqual(flow.saved[1].lyricsSource, "Generated from your audio", "nothing found online, so as heard")
        XCTAssertEqual(flow.saved.map(\.album), ["The Quiet Hours", "The Quiet Hours"], "the album name from the catalog")
        XCTAssertEqual(flow.plan?.artists, ["Ines Vale"])
    }
}
