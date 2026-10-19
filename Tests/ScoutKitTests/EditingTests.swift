import XCTest
import AVFoundation
import UIKit
@testable import ScoutKit

/// Editing imported songs and albums, and showing Scout's playlists as albums.
@MainActor final class EditingTests: XCTestCase {
    var work: URL!
    var library: ScoutLibrary!
    override func setUp() async throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support"))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work); AlbumDisplay.albums = [:] }

    func tone(_ seconds: Double) throws -> URL {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let url = work.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(8000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!; buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }
    func cover(_ color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).pngData { context in color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64)) }
    }
    func saveAlbum(_ titles: [String], cover: Data? = nil) async throws -> [SavedSong] {
        var saved: [SavedSong] = []
        for (index, title) in titles.enumerated() {
            var draft = SongDraft(song: await DownloadedSong.make(file: try tone(2.4 + Double(index)), source: nil, artwork: nil))
            draft.title = title; draft.artists = ["Ines Vale"]; draft.trackNumber = index + 1; draft.cover = cover
            saved.append(try await library.save(draft, lyrics: "[00:00.50]first line", lyricsSource: "LRCLIB", album: "The Quiet Hours", albumArtist: "Ines Vale"))
        }
        return saved
    }

    func testEditingASongRewritesItsTagsAndLyrics() async throws {
        let song = try await saveAlbum(["Night Bus"])[0]
        let oldLyricFiles = try XCTUnwrap(song.spotiLyricsFiles)
        let newCover = cover(.red)
        let edited = try await library.edit(song, title: "Night Bus (Demo)", artists: ["Ines Vale", "Juno Reyes"], album: "The Quiet Hours",
                                            trackNumber: 1, lyrics: "[00:01.00]new line", cover: newCover)
        XCTAssertEqual(edited.filename, song.filename, "the file keeps its name")
        XCTAssertEqual(library.songs.first?.title, "Night Bus (Demo)")
        let tags = await DownloadedSong.make(file: library.fileURL(edited), source: nil, artwork: nil)
        XCTAssertEqual(tags.taggedTitle, "Night Bus (Demo)")
        XCTAssertEqual(tags.taggedArtist, "Ines Vale, Juno Reyes")
        XCTAssertEqual(tags.embeddedArtwork, CoverArtwork.image(newCover)?.data)
        XCTAssertEqual(try String(contentsOf: library.fileURL(edited).deletingPathExtension().appendingPathExtension("lrc"), encoding: .utf8), "[00:01.00]new line")
        for name in oldLyricFiles where !(edited.spotiLyricsFiles ?? []).contains(name) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.spotiLyricsFolder.appendingPathComponent(name).path), "old spoti.pw lyrics removed")
        }
        XCTAssertFalse(edited.spotiLyricsFiles?.isEmpty ?? true)
        XCTAssertEqual(edited.lyricsSource, "Edited")
        // Reloaded from disk.
        let reloaded = ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support"))
        XCTAssertEqual(reloaded.songs.first?.artists, ["Ines Vale", "Juno Reyes"])
    }

    func testEditingWithoutACoverKeepsTheOneInTheFile() async throws {
        let original = cover(.blue)
        let song = try await saveAlbum(["Night Bus"], cover: original)[0]
        let edited = try await library.edit(song, title: "Night Bus", artists: ["Ines Vale"], album: "The Quiet Hours", trackNumber: 1, lyrics: nil, cover: nil)
        let embedded = await library.cover(of: edited)
        XCTAssertEqual(embedded, CoverArtwork.image(original)?.data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.fileURL(edited).deletingPathExtension().appendingPathExtension("lrc").path))
        XCTAssertNil(edited.lyrics)
    }

    func testEditingAnAlbumRenamesReordersAndRecoversEverySong() async throws {
        let songs = try await saveAlbum(["Night Bus", "Paper Boats"])
        let plan = try await library.plan(album: "The Quiet Hours", artists: ["Ines Vale"], cover: cover(.blue), songs: songs)
        let newCover = cover(.green)
        let edited = try await library.edit(plan, name: "Quiet Hours (Deluxe)", artists: ["Ines Vale", "Juno Reyes"], cover: newCover,
                                            order: [songs[1].id, songs[0].id])
        XCTAssertEqual(edited.name, "Quiet Hours (Deluxe)")
        XCTAssertEqual(edited.songIDs, [songs[1].id, songs[0].id])
        XCTAssertEqual(library.cover(of: edited), newCover)
        let retagged = library.songs(in: edited)
        XCTAssertEqual(retagged.map(\.title), ["Paper Boats", "Night Bus"])
        XCTAssertEqual(retagged.map(\.trackNumber), [1, 2])
        XCTAssertEqual(retagged.map(\.album), ["Quiet Hours (Deluxe)", "Quiet Hours (Deluxe)"])
        for song in retagged {
            let tags = await DownloadedSong.make(file: library.fileURL(song), source: nil, artwork: nil)
            XCTAssertEqual(tags.taggedAlbum, "Quiet Hours (Deluxe)")
            XCTAssertEqual(tags.embeddedArtwork, CoverArtwork.image(newCover)?.data)
        }
    }

    func testRetaggingAMadePlaylistsSongQueuesItAgainAndKeepsItsSpotifyName() async throws {
        let songs = try await saveAlbum(["Night Bus"])
        library.publisher = FixedPublisher()
        try await library.plan(album: "The Quiet Hours", artists: ["Ines Vale"], cover: nil, songs: songs)
        _ = await library.compileWaiting()
        let made = try XCTUnwrap(library.playlists.first)
        XCTAssertEqual(made.status, .published)
        let edited = try await library.edit(made, name: "Quiet Hours", artists: ["Ines Vale"], cover: nil, order: made.songIDs)
        XCTAssertEqual(edited.status, .pending, "the retagged songs need adding to the playlist again")
        XCTAssertEqual(edited.spotifyName, "The Quiet Hours")
        XCTAssertEqual(edited.playlistURI, made.playlistURI)
    }

    func testPlaylistSubtitlesReadAsAlbums() {
        XCTAssertEqual(AlbumDisplay.albumSubtitle(for: "Playlist • Anton", artists: "Ines Vale, Juno Reyes"), "Album • Ines Vale, Juno Reyes")
        XCTAssertEqual(AlbumDisplay.albumSubtitle(for: "Playliste · Anton", artists: "Ines Vale"), "Album · Ines Vale")
        XCTAssertEqual(AlbumDisplay.albumSubtitle(for: "Playlist", artists: "Ines Vale"), "Album")
        XCTAssertNil(AlbumDisplay.albumSubtitle(for: "Album • Ines Vale", artists: "Ines Vale"))
        XCTAssertNil(AlbumDisplay.albumSubtitle(for: "Playlists you love", artists: "Ines Vale"))
    }

    func testAScoutPlaylistRowShowsAsAnAlbumWithItsCover() throws {
        let folder = work.appendingPathComponent("Covers"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try cover(.green).write(to: folder.appendingPathComponent("c.png"))
        var plan = PlaylistPlan(id: UUID(), name: "The Quiet Hours", artists: ["Ines Vale"], coverFilename: "c.png", songIDs: [], status: .published,
                                playlistURI: "spotify:playlist:fixture", lastError: nil, createdAt: Date())
        plan.spotifyName = "The Quiet Hours"
        AlbumDisplay.index([plan], coverFolder: folder)

        let cell = UICollectionViewCell(frame: CGRect(x: 0, y: 0, width: 360, height: 64))
        let picture = UIImageView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        let spotifyPicture = UIImage(systemName: "music.note.list")
        picture.image = spotifyPicture
        let title = UILabel(), subtitle = UILabel()
        title.text = "The Quiet Hours"; subtitle.text = "Playlist • Anton"
        [picture, title, subtitle].forEach(cell.contentView.addSubview)
        AlbumDisplay.refresh(cell)
        XCTAssertEqual(subtitle.text, "Album • Ines Vale")
        XCTAssertNotEqual(picture.image, spotifyPicture)
        XCTAssertEqual(picture.image?.size, CGSize(width: 64, height: 64))
        // Spotify loading its own picture later keeps the cover...
        XCTAssertEqual(AlbumDisplay.image(for: picture, proposed: spotifyPicture)?.size, CGSize(width: 64, height: 64))
        // ...until the cell is reused for something else.
        title.text = "Liked Songs"
        XCTAssertEqual(AlbumDisplay.image(for: picture, proposed: spotifyPicture), spotifyPicture)
    }

    func testOtherRowsAreLeftAlone() {
        AlbumDisplay.index([PlaylistPlan(id: UUID(), name: "The Quiet Hours", artists: ["Ines Vale"], coverFilename: nil, songIDs: [], status: .published,
                                         playlistURI: "spotify:playlist:fixture", lastError: nil, createdAt: Date())], coverFolder: work)
        let cell = UICollectionViewCell(frame: CGRect(x: 0, y: 0, width: 360, height: 64))
        let title = UILabel(), subtitle = UILabel()
        title.text = "Road Trip"; subtitle.text = "Playlist • Anton"
        [title, subtitle].forEach(cell.contentView.addSubview)
        AlbumDisplay.refresh(cell)
        XCTAssertEqual(subtitle.text, "Playlist • Anton")
    }
}

private struct FixedPublisher: PlaylistPublishing {
    func publish(_ plan: PlaylistPlan, songs: [SavedSong]) async throws -> PlaylistPlan {
        var plan = plan; plan.status = .published; plan.playlistURI = "spotify:playlist:fixture"; plan.lastError = nil; return plan
    }
}
