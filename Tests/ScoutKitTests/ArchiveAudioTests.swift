import XCTest
@testable import ScoutKit

final class ArchiveAudioTests: XCTestCase {
    struct File: ArchiveAudioFile { var name: String; var original: String?; var format: String? }

    func testDownloadsTheMP3AndFallsBackToTheFLAC() {
        let songs = ArchiveAudio.songs(in: [
            File(name: "01 Song.flac", original: nil, format: "Flac"),
            File(name: "01 Song_64kb.mp3", original: "01 Song.flac", format: "64Kbps MP3"),
            File(name: "01 Song.mp3", original: "01 Song.flac", format: "VBR MP3"),
            File(name: "01 Song.ogg", original: "01 Song.flac", format: "Ogg Vorbis"),
            File(name: "01 Song_spectrogram.png", original: "01 Song.flac", format: "PNG"),
        ])
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(songs[0].download.name, "01 Song.mp3")
        XCTAssertEqual(songs[0].details.name, "01 Song.flac")
        XCTAssertEqual(songs[0].fallback?.name, "01 Song.flac")
    }

    func testAnUploadedMP3NeedsNoFallback() {
        let songs = ArchiveAudio.songs(in: [
            File(name: "Track.mp3", original: nil, format: "VBR MP3"),
            File(name: "Track_64kb.mp3", original: "Track.mp3", format: "64Kbps MP3"),
        ])
        XCTAssertEqual(songs.map(\.download.name), ["Track.mp3"])
        XCTAssertNil(songs[0].fallback)
    }

    func testWithoutAnMP3TheBestFileIsDownloaded() {
        let songs = ArchiveAudio.songs(in: [
            File(name: "Take.m4a", original: "Take.flac", format: "AAC"),
            File(name: "Take.flac", original: nil, format: "Flac"),
        ])
        XCTAssertEqual(songs.map(\.download.name), ["Take.flac"])
        XCTAssertNil(songs[0].fallback)
    }

    func testSeparatelyNamedVersionsStayApart() {
        let songs = ArchiveAudio.songs(in: [
            File(name: "Song (Demo).flac", original: nil, format: "Flac"),
            File(name: "Song (Demo).mp3", original: "Song (Demo).flac", format: "VBR MP3"),
            File(name: "Song.flac", original: nil, format: "Flac"),
            File(name: "Song.mp3", original: "Song.flac", format: "VBR MP3"),
        ])
        XCTAssertEqual(songs.map(\.download.name), ["Song (Demo).mp3", "Song.mp3"])
    }

    func testDownloadByteText() {
        XCTAssertEqual(DownloadManager.bytesText(received: 0, expected: 26_201_200), "Starting…")
        XCTAssertEqual(DownloadManager.bytesText(received: 3_260_000, expected: 26_201_200), "3.3 of 26.2 MB")
        XCTAssertEqual(DownloadManager.bytesText(received: 3_260_000, expected: -1), "3.3 MB")
    }
}
