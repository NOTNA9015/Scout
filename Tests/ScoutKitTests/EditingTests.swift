import XCTest
import AVFoundation
import UIKit
@testable import ScoutKit

/// Editing imported songs and albums.
@MainActor final class EditingTests: XCTestCase {
    var work: URL!
    var library: ScoutLibrary!
    override func setUp() async throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support"))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work) }

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
}

private struct FixedPublisher: PlaylistPublishing {
    func publish(_ plan: PlaylistPlan, songs: [SavedSong]) async throws -> PlaylistPlan {
        var plan = plan; plan.status = .published; plan.playlistURI = "spotify:playlist:fixture"; plan.lastError = nil; return plan
    }
}

/// Deleting and duplicates.
@MainActor final class DeletingTests: XCTestCase {
    var work: URL!
    var library: ScoutLibrary!
    override func setUp() async throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support"))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work) }

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
    func save(_ title: String, seconds: Double = 2.4) async throws -> SavedSong {
        var draft = SongDraft(song: await DownloadedSong.make(file: try tone(seconds), source: nil, artwork: nil))
        draft.title = title; draft.artists = ["Ines Vale"]
        return try await library.save(draft, lyrics: "[00:00.50]first line", lyricsSource: "LRCLIB", album: "The Quiet Hours", albumArtist: "Ines Vale")
    }
    /// Makes the album in a fake Spotify that has indexed its files.
    func publish(_ songs: [SavedSong]) async throws -> (FakeSpotify, PlaylistPlan) {
        let spotify = FakeSpotify()
        for song in songs {
            let file = library.fileURL(song)
            let seconds = Int(try await AVURLAsset(url: file).load(.duration).seconds.rounded(.down))
            await spotify.index(SpotiPWLyrics.localURI(artist: "Ines Vale", album: "The Quiet Hours", title: song.title, seconds: seconds), file.path)
        }
        library.publisher = SpotifyPlaylistPublisher(services: spotify, musicFolder: library.musicFolder, indexWait: [.zero])
        try await library.plan(album: "The Quiet Hours", artists: ["Ines Vale"], cover: nil, songs: songs)
        let result = await library.compileWaiting()
        XCTAssertEqual(result.made.count, 1, result.failed.first?.lastError ?? "")
        return (spotify, try XCTUnwrap(library.playlists.first))
    }

    func testDeletingASongRemovesItsFilesAndItsEntryInSpotify() async throws {
        let songs = [try await save("Night Bus"), try await save("Paper Boats", seconds: 3.4)]
        let (spotify, plan) = try await publish(songs)
        XCTAssertEqual(plan.trackURIs?.count, 2)
        let problem = await library.delete(songs[0])
        XCTAssertNil(problem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.fileURL(songs[0]).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.fileURL(songs[0]).deletingPathExtension().appendingPathExtension("lrc").path))
        for name in songs[0].spotiLyricsFiles ?? [] { XCTAssertFalse(FileManager.default.fileExists(atPath: library.spotiLyricsFolder.appendingPathComponent(name).path)) }
        XCTAssertEqual(library.songs.map(\.id), [songs[1].id])
        XCTAssertEqual(library.playlists.first?.songIDs, [songs[1].id])
        let tracks = await spotify.playlists[try XCTUnwrap(plan.playlistURI)]
        XCTAssertEqual(tracks?.count, 1); XCTAssertTrue(tracks?[0].contains("Paper+Boats") ?? false)
    }

    func testDeletingAnAlbumRemovesItsPlaylistAndOptionallyItsSongs() async throws {
        let songs = [try await save("Night Bus")]
        let (spotify, plan) = try await publish(songs)
        let firstProblem = await library.delete(plan, withSongs: false)
        XCTAssertNil(firstProblem)
        XCTAssertTrue(library.playlists.isEmpty)
        XCTAssertEqual(library.songs.count, 1, "songs kept")
        let gone = await spotify.playlists[try XCTUnwrap(plan.playlistURI)]
        XCTAssertNil(gone)

        let other = try await library.plan(album: "Second", artists: ["Ines Vale"], cover: nil, songs: songs)
        let secondProblem = await library.delete(other, withSongs: true)
        XCTAssertNil(secondProblem)
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.fileURL(songs[0]).path))
    }

    func testDeletingTheLastSongDeletesTheAlbum() async throws {
        let song = try await save("Night Bus")
        try await library.plan(album: "The Quiet Hours", artists: ["Ines Vale"], cover: nil, songs: [song])
        await library.delete(song)
        XCTAssertTrue(library.playlists.isEmpty)
    }

    func testImportingTheSameSongOrAlbumAgainReplacesIt() async throws {
        let first = try await save("Night Bus")
        let second = try await save("night  bus")
        XCTAssertEqual(library.songs.count, 1)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.filename, first.filename)
        let files = try FileManager.default.contentsOfDirectory(atPath: library.musicFolder.path).filter { !$0.hasSuffix(".lrc") }
        XCTAssertEqual(files.count, 1, "\(files)")

        try await library.plan(album: "The Quiet Hours", artists: ["Ines Vale"], cover: nil, songs: [first])
        let another = try await save("Paper Boats", seconds: 3.4)
        try await library.plan(album: "the quiet hours", artists: ["Ines Vale"], cover: nil, songs: [first, another, first])
        XCTAssertEqual(library.playlists.count, 1)
        XCTAssertEqual(library.playlists.first?.songIDs, [first.id, another.id])
    }

    func testDuplicatesAlreadySavedAreMerged() async throws {
        let a = try await save("Night Bus")
        // Two copies of the song and of the album, as older versions of Scout could leave them.
        let copyFile = library.musicFolder.appendingPathComponent("Ines Vale - Night Bus 2.m4a")
        try FileManager.default.copyItem(at: library.fileURL(a), to: copyFile)
        var copy = a; copy.id = UUID(); copy.filename = copyFile.lastPathComponent; copy.savedAt = a.savedAt.addingTimeInterval(-60)
        let support = work.appendingPathComponent("Support")
        try JSONEncoder().encode([a, copy]).write(to: support.appendingPathComponent("songs.json"))
        let plans = [a.id, copy.id].map { PlaylistPlan(id: UUID(), name: "The Quiet Hours", artists: ["Ines Vale"], coverFilename: nil, songIDs: [$0],
                                                       status: .pending, playlistURI: nil, lastError: nil, createdAt: Date()) }
        try JSONEncoder().encode(plans).write(to: support.appendingPathComponent("playlists.json"))
        library = ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: support)

        let removed = await library.removeDuplicates()
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(library.songs.map(\.id), [a.id], "the newest copy is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyFile.path))
        XCTAssertEqual(library.playlists.count, 1)
        XCTAssertEqual(library.playlists.first?.songIDs, [a.id])
    }

    func testTheReleaseDateIsTagged() async throws {
        let released = Date(timeIntervalSince1970: 1_312_800_000)
        var draft = SongDraft(song: await DownloadedSong.make(file: try tone(2.4), source: nil, artwork: nil))
        draft.title = "Night Bus"; draft.artists = ["Ines Vale"]
        let song = try await library.save(draft, lyrics: nil, lyricsSource: nil, album: "The Quiet Hours", albumArtist: "Ines Vale", releaseDate: released)
        let plan = try await library.plan(album: "The Quiet Hours", artists: ["Ines Vale"], cover: nil, releaseDate: released, songs: [song])
        XCTAssertEqual(plan.releaseDate, released)
        let items = try await AVURLAsset(url: library.fileURL(song)).load(.metadata)
        let tagged = try await AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .iTunesMetadataReleaseDate).first?.load(.stringValue)
        XCTAssertEqual(tagged, released.formatted(.iso8601.year().month().day().dateSeparator(.dash)))

        let later = Date(timeIntervalSince1970: 1_400_000_000)
        let edited = try await library.edit(plan, name: plan.name, artists: plan.artists, cover: nil, releaseDate: later, order: plan.songIDs)
        XCTAssertEqual(edited.releaseDate, later)
        let retagged = try await AVURLAsset(url: library.fileURL(song)).load(.metadata)
        let date = try await AVMetadataItem.metadataItems(from: retagged, filteredByIdentifier: .iTunesMetadataReleaseDate).first?.load(.stringValue)
        XCTAssertEqual(date, later.formatted(.iso8601.year().month().day().dateSeparator(.dash)), "editing the album's date retags its songs")
    }

}

extension DeletingTests {
    func testAnAlbumsSongsCanBeAddedAndRemoved() async throws {
        let a = try await save("Night Bus"), b = try await save("Paper Boats", seconds: 3.4), c = try await save("Salt and Cedar", seconds: 4.4)
        let first = try await library.plan(album: "The Quiet Hours", artists: ["Ines Vale"], cover: nil, songs: [a, b])
        let second = try await library.plan(album: "Other Album", artists: ["Ines Vale"], cover: nil, songs: [c])
        // Take Night Bus off, and move Salt and Cedar over from the other album.
        let edited = try await library.edit(first, name: first.name, artists: first.artists, cover: nil, order: [c.id, b.id])
        XCTAssertEqual(edited.songIDs, [c.id, b.id])
        XCTAssertNil(library.playlists.first { $0.id == second.id }, "an album left empty is gone")
        let single = try XCTUnwrap(library.songs.first { $0.id == a.id })
        XCTAssertNil(library.album(of: single))
        XCTAssertEqual(single.album, "Night Bus", "a single song again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.fileURL(single).path), "kept in Scout")
        XCTAssertEqual(library.songs.first { $0.id == c.id }?.album, "The Quiet Hours")
        XCTAssertEqual(library.songs.first { $0.id == c.id }?.trackNumber, 1)
        do { _ = try await library.edit(edited, name: edited.name, artists: edited.artists, cover: nil, order: []); XCTFail("an album needs a song") } catch {}
    }

    func testTakingASongOffAMadeAlbumRemovesItFromThePlaylist() async throws {
        let songs = [try await save("Night Bus"), try await save("Paper Boats", seconds: 3.4)]
        let (spotify, plan) = try await publish(songs)
        _ = try await library.edit(plan, name: plan.name, artists: plan.artists, cover: nil, order: [songs[1].id])
        let tracks = await spotify.playlists[try XCTUnwrap(plan.playlistURI)]
        XCTAssertEqual(tracks?.count, 1); XCTAssertTrue(tracks?[0].contains("Paper+Boats") ?? false)
    }
}
