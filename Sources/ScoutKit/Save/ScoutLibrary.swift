import Foundation
import AVFoundation

/// A song Scout saved into Spotify's local files.
public struct SavedSong: Codable, Identifiable, Equatable {
    public var id: UUID
    public var filename: String          // inside ScoutLibrary.musicFolder
    public var title: String
    public var artists: [String]
    public var album: String
    public var trackNumber: Int
    public var lyrics: String?
    public var lyricsSource: String?
    public var savedAt: Date
    /// Files written into spoti.pw's own lyrics folder for this song.
    public var spotiLyricsFiles: [String]? = nil
    public var duration: Double? = nil
}

/// An album waiting to become a Spotify playlist. Scout records the plan now; publishing it
/// (resolving each file's spotify:local: URI and creating the playlist) is a later step.
public struct PlaylistPlan: Codable, Identifiable, Equatable {
    public enum Status: String, Codable { case pending, published, failed }
    public var id: UUID
    public var name: String
    public var artists: [String]
    public var coverFilename: String?    // inside ScoutLibrary.supportFolder/Covers
    public var songIDs: [UUID]           // in album order
    public var status: Status
    public var playlistURI: String?
    public var lastError: String?
    public var createdAt: Date
    /// Set when a create request went to Spotify; cleared once its playlist URI is known.
    public var creationStartedAt: Date? = nil
    /// The name the Spotify playlist was made with, kept when the album is renamed in Scout
    /// afterwards (Scout doesn't rename playlists in Spotify).
    public var spotifyName: String? = nil
}

/// Turns a plan into a real playlist (SpotifyPlaylistPublisher inside Spotify).
public protocol PlaylistPublishing {
    func publish(_ plan: PlaylistPlan, songs: [SavedSong]) async throws -> PlaylistPlan
}
public struct PendingPlaylistPublisher: PlaylistPublishing {
    public init() {}
    public func publish(_ plan: PlaylistPlan, songs: [SavedSong]) async throws -> PlaylistPlan {
        var plan = plan; plan.status = .failed; plan.lastError = "Playlists are made inside Spotify."; return plan
    }
}

@MainActor public final class ScoutLibrary: ObservableObject {
    public static let shared = ScoutLibrary()
    @Published public private(set) var songs: [SavedSong] = []
    @Published public private(set) var playlists: [PlaylistPlan] = []
    @Published public private(set) var publishing: Set<UUID> = []
    public let musicFolder: URL
    public let supportFolder: URL
    /// spoti.pw's lyrics folder, beside Scout's in Application Support.
    public var spotiLyricsFolder: URL { SpotiPWLyrics.folder(applicationSupport: supportFolder.deletingLastPathComponent()) }
    public var publisher: PlaylistPublishing = PendingPlaylistPublisher()

    /// Spotify's local-files scanner reads the app's Documents folder (Files → On My iPhone → Spotify).
    public init(documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
                support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scout", isDirectory: true)) {
        musicFolder = documents.appendingPathComponent("Scout", isDirectory: true)
        supportFolder = support
        songs = (try? JSONDecoder().decode([SavedSong].self, from: Data(contentsOf: support.appendingPathComponent("songs.json")))) ?? []
        playlists = (try? JSONDecoder().decode([PlaylistPlan].self, from: Data(contentsOf: support.appendingPathComponent("playlists.json")))) ?? []
    }
    public func fileURL(_ song: SavedSong) -> URL { musicFolder.appendingPathComponent(song.filename) }

    /// Writes one song: tags (incl. cover and lyrics) into the audio, an .lrc beside it, and
    /// the manifest entry. The staged download is left for the caller to clean up.
    public func save(_ draft: SongDraft, lyrics: String?, lyricsSource: String?, album: String? = nil, albumArtist: String? = nil, forceAAC: Bool = false) async throws -> SavedSong {
        try FileManager.default.createDirectory(at: musicFolder, withIntermediateDirectories: true)
        let artist = draft.artistText
        let ext = forceAAC ? "m4a" : TagWriter.outputExtension(for: draft.song.file)
        let base = Self.safeName((artist.isEmpty ? "" : artist + " - ") + draft.title)
        var name = base + "." + ext, counter = 2
        while FileManager.default.fileExists(atPath: musicFolder.appendingPathComponent(name).path) { name = "\(base) \(counter).\(ext)"; counter += 1 }
        let destination = musicFolder.appendingPathComponent(name)
        let albumName = album ?? (draft.album.isEmpty ? draft.title : draft.album)
        let tags = TagWriter.Tags(title: draft.title, artist: artist, album: albumName, albumArtist: albumArtist ?? artist,
                                  trackNumber: draft.trackNumber, artwork: draft.cover, lyrics: lyrics)
        do { try await TagWriter.write(tags, from: draft.song.file, to: destination, forceAAC: forceAAC) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        // An .lrc beside the audio for other players; spoti.pw reads its own lyrics folder, keyed
        // by the spotify:local: URI Spotify gives this file.
        var spotiFiles: [String]?
        if let lyrics {
            try? lyrics.write(to: destination.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
            let length = (try? await AVURLAsset(url: destination).load(.duration).seconds) ?? draft.song.duration
            spotiFiles = try? SpotiPWLyrics.write(lyrics, artist: tags.artist, album: tags.album, title: tags.title, duration: length, into: spotiLyricsFolder)
        }
        var saved = SavedSong(id: draft.id, filename: name, title: draft.title, artists: draft.artists, album: albumName,
                              trackNumber: draft.trackNumber, lyrics: lyrics, lyricsSource: lyricsSource, savedAt: Date())
        saved.duration = try AudioCompatibility.inspect(destination).duration
        saved.spotiLyricsFiles = spotiFiles
        songs.append(saved)
        try persist()
        return saved
    }

    /// Records the album as a pending playlist. It is made when the user taps Compile pending
    /// playlists on Spotify's Local Files page, where Spotify's services are sure to be up.
    @discardableResult
    public func plan(album name: String, artists: [String], cover: Data?, songs saved: [SavedSong]) async throws -> PlaylistPlan {
        var coverName: String?
        if let cover {
            let folder = supportFolder.appendingPathComponent("Covers", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            coverName = UUID().uuidString + (cover.starts(with: [137, 80, 78, 71]) ? ".png" : ".jpg")
            try cover.write(to: folder.appendingPathComponent(coverName!), options: .atomic)
        }
        let plan = PlaylistPlan(id: UUID(), name: name, artists: artists, coverFilename: coverName, songIDs: saved.map(\.id),
                                status: .pending, playlistURI: nil, lastError: nil, createdAt: Date())
        playlists.append(plan); try persist()
        return plan
    }
    /// Songs whose audio file is gone (deleted in Files or Spotify) are forgotten, with the lyrics
    /// Scout wrote for them. Albums still waiting lose those songs, and an album with none left
    /// is dropped. Playlists already made are left alone; they live in Spotify now.
    @discardableResult
    public func forgetMissingFiles() -> Int {
        let missing = songs.filter { !FileManager.default.fileExists(atPath: fileURL($0).path) }
        guard !missing.isEmpty else { return 0 }
        for song in missing {
            try? FileManager.default.removeItem(at: fileURL(song).deletingPathExtension().appendingPathExtension("lrc"))
            for name in song.spotiLyricsFiles ?? [] { try? FileManager.default.removeItem(at: spotiLyricsFolder.appendingPathComponent(name)) }
        }
        let gone = Set(missing.map(\.id))
        songs.removeAll { gone.contains($0.id) }
        playlists = playlists.compactMap { plan in
            guard plan.status != .published, !publishing.contains(plan.id) else { return plan }
            var plan = plan
            plan.songIDs.removeAll { gone.contains($0) }
            if plan.songIDs.isEmpty {
                if let cover = plan.coverFilename { try? FileManager.default.removeItem(at: supportFolder.appendingPathComponent("Covers").appendingPathComponent(cover)) }
                return nil
            }
            return plan
        }
        try? persist()
        return missing.count
    }
    // MARK: Editing what was imported

    /// The album a saved song belongs to, if it was imported as part of one.
    public func album(of song: SavedSong) -> PlaylistPlan? { playlists.first { $0.songIDs.contains(song.id) } }
    public func songs(in plan: PlaylistPlan) -> [SavedSong] { plan.songIDs.compactMap { id in songs.first { $0.id == id } } }
    public func coverURL(_ plan: PlaylistPlan) -> URL? {
        plan.coverFilename.map { supportFolder.appendingPathComponent("Covers").appendingPathComponent($0) }
    }
    public func cover(of plan: PlaylistPlan) -> Data? { coverURL(plan).flatMap { try? Data(contentsOf: $0) } }
    /// The cover embedded in the song's file.
    public func cover(of song: SavedSong) async -> Data? {
        await DownloadedSong.make(file: fileURL(song), source: nil, artwork: nil).embeddedArtwork
    }

    /// Rewrites one song's tags, .lrc and spoti.pw lyrics with new details. The file keeps its name.
    /// A nil cover keeps the one already in the file.
    public func edit(_ song: SavedSong, title: String, artists: [String], album: String, trackNumber: Int,
                     lyrics: String?, cover: Data?) async throws -> SavedSong {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { throw ScoutError.message("This song is no longer in Scout.") }
        let plan = self.album(of: song)
        let artist = Suggestions.joinArtists(artists)
        let albumArtist = plan.map { Suggestions.joinArtists($0.artists) } ?? artist
        var artwork = cover
        if artwork == nil { artwork = await self.cover(of: song) }
        let lyrics = lyrics.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let file = fileURL(song)
        let tags = TagWriter.Tags(title: title, artist: artist, album: album, albumArtist: albumArtist.isEmpty ? artist : albumArtist,
                                  trackNumber: trackNumber, artwork: artwork, lyrics: lyrics)
        // Write beside the original first, so a failure leaves the song as it was.
        let staged = file.deletingLastPathComponent().appendingPathComponent(".scout-edit-" + UUID().uuidString + "." + file.pathExtension)
        do { try await TagWriter.write(tags, from: file, to: staged) }
        catch { try? FileManager.default.removeItem(at: staged); throw error }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: staged)

        // spoti.pw keys lyrics by the spotify:local: URI, which follows the tags; replace the old files.
        for name in song.spotiLyricsFiles ?? [] { try? FileManager.default.removeItem(at: spotiLyricsFolder.appendingPathComponent(name)) }
        let lrc = file.deletingPathExtension().appendingPathExtension("lrc")
        var edited = song
        edited.title = title; edited.artists = artists; edited.album = album; edited.trackNumber = trackNumber
        edited.lyrics = lyrics; edited.spotiLyricsFiles = nil
        edited.duration = (try? AudioCompatibility.inspect(file).duration) ?? song.duration
        if let lyrics {
            if lyrics != song.lyrics { edited.lyricsSource = "Edited" }
            try? lyrics.write(to: lrc, atomically: true, encoding: .utf8)
            edited.spotiLyricsFiles = try? SpotiPWLyrics.write(lyrics, artist: tags.artist, album: tags.album, title: tags.title,
                                                               duration: edited.duration ?? 0, into: spotiLyricsFolder)
        } else {
            try? FileManager.default.removeItem(at: lrc)
            edited.lyricsSource = nil
        }
        songs[index] = edited
        // Spotify knows a local file by its tags, so a made playlist needs the song added again.
        if let plan, plan.status == .published, Self.identityChanged(song, edited) {
            var plan = plan; plan.status = .pending; plan.lastError = nil; update(plan)
        }
        try persist()
        return edited
    }
    static func identityChanged(_ a: SavedSong, _ b: SavedSong) -> Bool {
        a.title != b.title || a.artists != b.artists || a.album != b.album
    }

    /// Renames, re-credits, re-covers or re-orders an album, rewriting every song's tags to match.
    /// A nil cover keeps the album's cover.
    public func edit(_ plan: PlaylistPlan, name: String, artists: [String], cover: Data?, order: [UUID]) async throws -> PlaylistPlan {
        guard var edited = playlists.first(where: { $0.id == plan.id }) else { throw ScoutError.message("This album is no longer in Scout.") }
        if let cover {
            let folder = supportFolder.appendingPathComponent("Covers", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let coverName = UUID().uuidString + (cover.starts(with: [137, 80, 78, 71]) ? ".png" : ".jpg")
            try cover.write(to: folder.appendingPathComponent(coverName), options: .atomic)
            if let old = edited.coverFilename { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
            edited.coverFilename = coverName
        }
        if edited.playlistURI != nil, edited.spotifyName == nil { edited.spotifyName = edited.name }
        edited.name = name; edited.artists = artists
        edited.songIDs = order.filter(edited.songIDs.contains) + edited.songIDs.filter { !order.contains($0) }
        update(edited)
        let albumCover = cover ?? self.cover(of: edited)
        for (number, song) in songs(in: edited).enumerated() {
            _ = try await edit(song, title: song.title, artists: song.artists, album: name, trackNumber: number + 1,
                               lyrics: song.lyrics, cover: albumCover)
        }
        return playlists.first { $0.id == plan.id } ?? edited
    }

    /// Albums not yet made into playlists.
    public var waiting: [PlaylistPlan] { playlists.filter { $0.status != .published } }
    /// Compile pending playlists: makes every waiting album, one after another, and says how it went.
    /// A create Spotify never confirmed is only repeated on the second tap, after the user was told
    /// to check Your Library, so no duplicate playlists.
    public func compileWaiting() async -> (made: [PlaylistPlan], failed: [PlaylistPlan]) {
        forgetMissingFiles()
        var made: [PlaylistPlan] = [], failed: [PlaylistPlan] = []
        for var plan in waiting where !publishing.contains(plan.id) {
            if plan.playlistURI == nil, plan.creationStartedAt != nil, plan.lastError == Self.unconfirmed { plan.creationStartedAt = nil }
            plan.status = .pending; plan.lastError = nil; update(plan)
            let songs = plan.songIDs.compactMap { id in self.songs.first { $0.id == id } }
            publishing.insert(plan.id)
            let result = (try? await publisher.publish(plan, songs: songs)) ?? plan
            publishing.remove(plan.id); update(result)
            if result.status == .published { made.append(result) } else { failed.append(result) }
        }
        return (made, failed)
    }
    static let unconfirmed = SpotifyPlaylistPublisher.unconfirmed
    private func update(_ plan: PlaylistPlan) {
        if let index = playlists.firstIndex(where: { $0.id == plan.id }) { playlists[index] = plan; try? persist() }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: supportFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(songs).write(to: supportFolder.appendingPathComponent("songs.json"), options: .atomic)
        try JSONEncoder().encode(playlists).write(to: supportFolder.appendingPathComponent("playlists.json"), options: .atomic)
    }
    static func safeName(_ text: String) -> String {
        let cleaned = text.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\u{0}")).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return String((cleaned.isEmpty ? "Song" : cleaned).prefix(120))
    }
}
