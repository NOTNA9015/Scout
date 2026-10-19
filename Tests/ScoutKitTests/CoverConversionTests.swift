import XCTest
import AVFoundation
import UIKit
@testable import ScoutKit

@MainActor final class CoverConversionTests: XCTestCase {
    private var work: URL!
    override func setUp() async throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work) }
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }
    private func cover() throws -> Data { try Data(contentsOf: fixture("cover", "bin")) }
    private func assertCover(_ file: URL, equals expected: Data) async throws {
        let asset = AVURLAsset(url: file)
        let metadata = try await asset.loadMetadata(for: .iTunesMetadata)
        let art = try XCTUnwrap(metadata.first(where: { $0.identifier == .iTunesMetadataCoverArt }))
        let data = try await art.load(.dataValue)
        XCTAssertEqual(data, expected)
        XCTAssertEqual(art.dataType, kCMMetadataBaseDataType_PNG as String)
    }

    func testChosenCoverIsEmbeddedAsPNGInConvertedFile() async throws {
        let temporary = work.appendingPathComponent("download")
        try FileManager.default.copyItem(at: fixture("covered", "ogg"), to: temporary)
        let track = ScoutTrack(title: "Test", artist: "Artist", album: "Album", audioURL: "https://example.com/audio")
        let song = try await DownloadedAudio.prepare(temporary, track: track, into: work)
        let library = ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support"))
        XCTAssertEqual(song.embeddedArtwork, try cover())
        let selected = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        var draft = SongDraft(song: song); draft.cover = selected
        let saved = try await library.save(draft, lyrics: nil, lyricsSource: nil)
        try await assertCover(library.fileURL(saved), equals: selected)
    }

    func testEmbeddedOggCoverSurvivesAutomaticConversion() async throws {
        let temporary = work.appendingPathComponent("download")
        try FileManager.default.copyItem(at: fixture("covered", "ogg"), to: temporary)
        let track = ScoutTrack(title: "Test", artist: "Artist", album: "Album", audioURL: "https://example.com/audio")
        let song = try await DownloadedAudio.prepare(temporary, track: track, into: work)
        XCTAssertEqual(song.embeddedArtwork, try cover())
        try await assertCover(song.file, equals: cover())
    }

    func testEmbeddedFLACCoverSurvivesFileConverter() async throws {
        let original = try fixture("covered", "flac")
        XCTAssertEqual(CoverArtwork.embedded(in: original), try cover())
        let read = await DownloadedSong.make(file: original, source: nil, artwork: nil)
        XCTAssertEqual(read.embeddedArtwork, try cover())
        let library = ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support"))
        let converter = AudioFileConverter(library: library)
        await converter.add([try fixture("covered", "flac")])
        await converter.convert()
        let saved = try XCTUnwrap(converter.items.first?.saved)
        try await assertCover(library.fileURL(saved), equals: cover())
    }

    func testCoverAndTitleSurviveMissingArtistAndBlankLyrics() async throws {
        let target = work.appendingPathComponent("converted.m4a")
        let tags = TagWriter.Tags(title: "Test song", artist: "", album: "", albumArtist: "", trackNumber: 0, artwork: try cover(), lyrics: "")
        try await TagWriter.write(tags, from: fixture("tone", "flac"), to: target)
        try await assertCover(target, equals: cover())
        let read = await DownloadedSong.make(file: target, source: nil, artwork: nil)
        XCTAssertEqual(read.taggedTitle, "Test song")
        XCTAssertNil(read.taggedArtist)
    }
}
