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

/// Deleting, duplicates, and what an album's own page looks like.
@MainActor final class DeletingTests: XCTestCase {
    var work: URL!
    var library: ScoutLibrary!
    override func setUp() async throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support"))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work); AlbumDisplay.albums = [:]; AlbumDisplay.songTitles = [] }

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

    func testAnAlbumPageShowsTheArtistAndNoCoversOnItsSongs() throws {
        let songID = UUID()
        let plan = PlaylistPlan(id: UUID(), name: "The Quiet Hours", artists: ["Ines Vale"], coverFilename: nil, songIDs: [songID], status: .published,
                                playlistURI: "spotify:playlist:fixture", lastError: nil, createdAt: Date())
        let song = SavedSong(id: songID, filename: "x.m4a", title: "Night Bus", artists: ["Ines Vale"], album: "The Quiet Hours", trackNumber: 1,
                             lyrics: nil, lyricsSource: nil, savedAt: Date())
        AlbumDisplay.index([plan], songs: [song], coverFolder: work)
        AlbumDisplay.ownerNames = ["Anton"]

        let page = FakePlaylistPage(); page.loadViewIfNeeded()
        let owner = UILabel(), kind = UILabel(), description = UILabel()
        owner.text = "Anton"; kind.text = "Playlist"; description.text = "Ines Vale"
        let row = UICollectionViewCell(frame: CGRect(x: 0, y: 300, width: 360, height: 56))
        let art = UIImageView(frame: CGRect(x: 0, y: 0, width: 48, height: 48)); let title = UILabel(); title.text = "Night Bus"
        [art, title].forEach(row.contentView.addSubview)
        let other = UICollectionViewCell(frame: CGRect(x: 0, y: 360, width: 360, height: 56))
        let otherArt = UIImageView(frame: CGRect(x: 0, y: 0, width: 48, height: 48)); let otherTitle = UILabel(); otherTitle.text = "Something Else"
        [otherArt, otherTitle].forEach(other.contentView.addSubview)
        [owner, kind, description, row, other].forEach(page.view.addSubview)

        AlbumDisplay.attach(to: page)
        XCTAssertEqual(owner.text, "Ines Vale", "the artist in the owner's place")
        let year = Calendar.current.component(.year, from: Date())
        XCTAssertEqual(kind.text, "Album • \(year)")
        XCTAssertTrue(description.isHidden, "no second line of artists")
        XCTAssertTrue(art.isHidden, "album pages show no cover on each song")
        XCTAssertFalse(otherArt.isHidden)

        // The row is reused for a song from somewhere else: its cover comes back.
        title.text = "Another Song"
        AlbumDisplay.refreshPage(around: title)
        XCTAssertFalse(art.isHidden)
    }
}

/// A page that names its playlist the way Spotify's pages do.
private final class FakePlaylistPage: UIViewController {
    @objc var pageURI: String { "spotify:playlist:fixture" }
}
