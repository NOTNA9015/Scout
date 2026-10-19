import XCTest
import AVFoundation
@testable import ScoutKit

@MainActor final class AudioCompatibilityTests: XCTestCase {
    private var work: URL!
    private let tags = TagWriter.Tags(title: "Test song", artist: "Test artist", album: "Test album", albumArtist: "Test artist", trackNumber: 1, artwork: nil, lyrics: "[00:00.10]Test words")
    override func setUp() async throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work) }
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }
    private func checkAAC(_ url: URL, duration: Double = 1.25) throws {
        let info = try AudioCompatibility.inspect(url)
        XCTAssertEqual(info.codec, kAudioFormatMPEG4AAC)
        XCTAssertEqual(info.rate, 44100)
        XCTAssertLessThanOrEqual(info.channels, 2)
        XCTAssertEqual(info.duration, duration, accuracy: 0.1)
    }

    func testMislabeledFLACIsSavedAsActualAACWithTags() async throws {
        let source = work.appendingPathComponent("wrong.mp3"), target = work.appendingPathComponent("correct.m4a")
        try FileManager.default.copyItem(at: fixture("tone", "flac"), to: source)
        let original = try Data(contentsOf: source)
        XCTAssertEqual(TagWriter.outputExtension(for: source), "m4a")
        try await TagWriter.write(tags, from: source, to: target)
        try checkAAC(target)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let song = await DownloadedSong.make(file: target, source: nil, artwork: nil)
        XCTAssertEqual(song.taggedTitle, tags.title)
        XCTAssertEqual(song.taggedArtist, tags.artist)
        XCTAssertEqual(song.taggedAlbum, tags.album)
        XCTAssertEqual(song.taggedLyrics, tags.lyrics)
    }

    func testAudioIsIdentifiedWithoutAnyFileExtension() throws {
        let source = work.appendingPathComponent("tracker-api-response")
        try FileManager.default.copyItem(at: fixture("tone", "flac"), to: source)
        XCTAssertEqual(try AudioCompatibility.envelope(source).ext, "flac")
        let normalized = try AudioCompatibility.normalizedCopy(source, into: work)
        XCTAssertEqual(try AudioCompatibility.inspect(normalized).codec, kAudioFormatFLAC)
    }

    func testOggOpusMasqueradingAsMP3IsConvertedImmediatelyAfterDownload() async throws {
        let temporary = work.appendingPathComponent("false-mp3-response"), staging = work.appendingPathComponent("Staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture("tone", "ogg"), to: temporary)
        XCTAssertEqual(try AudioCompatibility.envelope(temporary).ext, "ogg")
        var converting = false
        let source = ScoutTrack(title: "Done*", artist: "Frank Ocean", album: "Lonny Breaux", audioURL: "https://example.com/false.mp3")
        let song = try await DownloadedAudio.prepare(temporary, track: source, into: staging) { _ in converting = true }
        XCTAssertTrue(converting)
        XCTAssertEqual(song.file.pathExtension, "m4a")
        XCTAssertEqual(song.source, source)
        try checkAAC(song.file)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path).count, 1, "the unsupported intermediate is removed")
        let tagged = await DownloadedSong.make(file: song.file, source: nil, artwork: nil)
        XCTAssertEqual(tagged.taggedTitle, source.title)
    }

    func testSupportedDownloadsAreNotReencoded() async throws {
        let source = try fixture("tone", "mp3"), temporary = work.appendingPathComponent("download")
        try FileManager.default.copyItem(at: source, to: temporary)
        let original = try Data(contentsOf: source)
        var converting = false
        let track = ScoutTrack(title: "T", artist: "A", album: "B", audioURL: "https://example.com/audio")
        let song = try await DownloadedAudio.prepare(temporary, track: track, into: work) { _ in converting = true }
        XCTAssertFalse(converting)
        XCTAssertEqual(song.file.pathExtension, "mp3")
        XCTAssertEqual(try Data(contentsOf: song.file), original)
    }

    func testRepairsOldMP3TagsWrappedAroundFLAC() async throws {
        let source = work.appendingPathComponent("old.mp3"), target = work.appendingPathComponent("fixed.m4a")
        let audio = try Data(contentsOf: fixture("tone", "flac"))
        try (Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, 0]) + audio).write(to: source)
        XCTAssertEqual(try AudioCompatibility.envelope(source).ext, "flac")
        XCTAssertEqual(try AudioCompatibility.envelope(source).audioOffset, 10)
        try await TagWriter.write(tags, from: source, to: target)
        try checkAAC(target)
    }

    func testOldHighSampleRateALACBecomesAAC() async throws {
        let source = try fixture("lossless", "m4a"), target = work.appendingPathComponent("fixed.m4a")
        XCTAssertEqual(try AudioCompatibility.inspect(source).codec, kAudioFormatAppleLossless)
        try await TagWriter.write(tags, from: source, to: target)
        try checkAAC(target)
    }

    func testRealMP3StaysMP3AndCanAlsoBeConverted() async throws {
        let source = try fixture("tone", "mp3"), mp3 = work.appendingPathComponent("tagged.mp3"), aac = work.appendingPathComponent("converted.m4a")
        XCTAssertEqual(TagWriter.outputExtension(for: source), "mp3")
        try await TagWriter.write(tags, from: source, to: mp3)
        XCTAssertEqual(try AudioCompatibility.inspect(mp3).codec, kAudioFormatMPEGLayer3)
        XCTAssertEqual(try AudioCompatibility.inspect(mp3).duration, try AudioCompatibility.inspect(source).duration, accuracy: 0.001)
        try await TagWriter.write(tags, from: source, to: aac, forceAAC: true)
        try checkAAC(aac)
    }

    func testConverterMakesNewCopiesPreservingMetadataAndOriginal() async throws {
        let library = ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support"))
        let staged = await DownloadedSong.make(file: try fixture("lossless", "m4a"), source: nil, artwork: nil)
        var draft = SongDraft(song: staged)
        draft.title = tags.title; draft.artists = [tags.artist]; draft.album = tags.album
        let first = try await library.save(draft, lyrics: tags.lyrics, lyricsSource: "Test")
        let originalURL = library.fileURL(first), original = try Data(contentsOf: originalURL)
        let converter = AudioFileConverter(library: library)
        await converter.add([originalURL])
        XCTAssertTrue(converter.canConvert)
        XCTAssertEqual(converter.items.first?.title, tags.title)
        await converter.convert()
        let converted = try XCTUnwrap(converter.items.first?.saved)
        XCTAssertNotEqual(converted.filename, first.filename)
        XCTAssertEqual(converted.title, first.title)
        XCTAssertEqual(converted.artists, first.artists)
        XCTAssertEqual(converted.lyrics, tags.lyrics)
        XCTAssertNotNil(converted.duration)
        try checkAAC(library.fileURL(converted))
        XCTAssertEqual(try Data(contentsOf: originalURL), original)
        XCTAssertFalse(converter.canConvert)
        await converter.convert()
        XCTAssertEqual(library.songs.count, 2, "completed conversions are not repeated")
    }

    func testDocumentDisguisedAsAudioCannotBeImported() async throws {
        let source = work.appendingPathComponent("download.mp3")
        try "<!doctype html><p>File not found</p>".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AudioCompatibility.envelope(source))
        let library = ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support"))
        let converter = AudioFileConverter(library: library)
        await converter.add([source])
        XCTAssertFalse(converter.canConvert)
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertEqual(converter.items.first?.format, "Unreadable audio")
    }

    func testMissingDurationsAreMeasuredFromTheActualAudio() async throws {
        let url = try fixture("tone", "flac")
        let track = ScoutTrack(title: "Test", artist: "A", album: "B", audioURL: url.absoluteString)
        let duration = await TrackDurationLookup.shared.duration(for: track)
        XCTAssertEqual(try XCTUnwrap(duration), 1.25, accuracy: 0.05)
        let cached = await TrackDurationLookup.shared.duration(for: track)
        XCTAssertEqual(cached, duration)
    }
}

final class TrackTimeTests: XCTestCase {
    func testParsesSourceLengthsWithoutInventingUnknownTimes() {
        XCTAssertEqual(TrackTime.parse("03:42.50"), 222.5)
        XCTAssertEqual(TrackTime.parse("1:02:03"), 3723)
        XCTAssertEqual(TrackTime.parse("222.5"), 222.5)
        for text in ["?:??", "N/A", "", "0", "nan", "inf", "1e99", "-1", "3:70", "1::20"] { XCTAssertNil(TrackTime.parse(text), text) }
        XCTAssertEqual(TrackTime.text(222), "3:42")
        XCTAssertEqual(TrackTime.text(3723), "1:02:03")
        XCTAssertEqual(TrackTime.text(nil), "Length unavailable")
        XCTAssertEqual(TrackTime.text(.infinity), "Length unavailable")
    }
    func testOldSourceManifestsStillDecodeWithoutADuration() throws {
        let json = #"{"name":"Old source","tracks":[{"title":"T","artist":"A","album":"B","audioURL":"https://example.com/test.mp3"}]}"#
        let source = try JSONDecoder().decode(SourceManifest.self, from: Data(json.utf8))
        XCTAssertNil(source.tracks[0].duration)
    }
    func testCatalogLengthsAreRetained() {
        XCTAssertEqual(CatalogSearch.apple(["trackName": "T", "trackTimeMillis": 222000.0])?.duration, 222)
        XCTAssertEqual(CatalogSearch.deezer(["title": "T", "duration": 222.0])?.duration, 222)
    }
}
