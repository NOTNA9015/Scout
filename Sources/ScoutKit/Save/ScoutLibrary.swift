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
    /// A copy made by the File converter, kept beside its original rather than replacing it.
    public var isConvertedCopy: Bool? = nil
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
    /// Each song's spotify:local: URI in the made playlist (by song id), so a song can be taken
    /// out of it again.
    public var trackURIs: [String: String]? = nil
    /// When the album came out; written into its songs' tags.
    public var releaseDate: Date? = nil
}

/// Turns a plan into a real playlist (SpotifyPlaylistPublisher inside Spotify), and takes songs
/// or the whole playlist out of Spotify again.
public protocol PlaylistPublishing {
    func publish(_ plan: PlaylistPlan, songs: [SavedSong]) async throws -> PlaylistPlan
    func remove(tracks: [String], from playlist: String) async throws
    func delete(playlist: String) async throws
}
public extension PlaylistPublishing {
    func remove(tracks: [String], from playlist: String) async throws {}
    func delete(playlist: String) async throws {}
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
    public func save(_ draft: SongDraft, lyrics: String?, lyricsSource: String?, album: String? = nil, albumArtist: String? = nil, releaseDate: Date? = nil, forceAAC: Bool = false) async throws -> SavedSong {
        try FileManager.default.createDirectory(at: musicFolder, withIntermediateDirectories: true)
        let artist = draft.artistText
        let ext = forceAAC ? "m4a" : TagWriter.outputExtension(for: draft.song.file)
        let albumName = album ?? (draft.album.isEmpty ? draft.title : draft.album)
        // The same song (name, artists, album) imported again replaces the one Scout already has.
        let key = Self.songKey(title: draft.title, artists: draft.artists, album: albumName, copy: forceAAC)
        let existing = songs.first { Self.songKey($0) == key }
        let name: String
        if let existing, existing.filename.hasSuffix("." + ext) { name = existing.filename }
        else {
            let base = Self.safeName((artist.isEmpty ? "" : artist + " - ") + draft.title)
            var candidate = base + "." + ext, counter = 2
            while FileManager.default.fileExists(atPath: musicFolder.appendingPathComponent(candidate).path) { candidate = "\(base) \(counter).\(ext)"; counter += 1 }
            name = candidate
        }
        let destination = musicFolder.appendingPathComponent(name)
        let tags = TagWriter.Tags(title: draft.title, artist: artist, album: albumName, albumArtist: albumArtist ?? artist,
                                  trackNumber: draft.trackNumber, artwork: draft.cover, lyrics: lyrics, releaseDate: releaseDate)
        let staged = musicFolder.appendingPathComponent(".scout-save-" + UUID().uuidString + "." + ext)
        do { try await TagWriter.write(tags, from: draft.song.file, to: staged, forceAAC: forceAAC) }
        catch { try? FileManager.default.removeItem(at: staged); throw error }
        if let existing {
            removeFiles(of: existing, keepAudio: existing.filename == name)
            songs.removeAll { $0.id == existing.id }
        }
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: destination) }
        // An .lrc beside the audio for other players; spoti.pw reads its own lyrics folder, keyed
        // by the spotify:local: URI Spotify gives this file.
        var spotiFiles: [String]?
        if let lyrics {
            try? lyrics.write(to: destination.deletingPathExtension().appendingPathExtension("lrc"), atomically: true, encoding: .utf8)
            let length = (try? await AVURLAsset(url: destination).load(.duration).seconds) ?? draft.song.duration
            spotiFiles = try? SpotiPWLyrics.write(lyrics, artist: tags.artist, album: tags.album, title: tags.title, duration: length, into: spotiLyricsFolder)
        }
        var saved = SavedSong(id: existing?.id ?? draft.id, filename: name, title: draft.title, artists: draft.artists, album: albumName,
                              trackNumber: draft.trackNumber, lyrics: lyrics, lyricsSource: lyricsSource, savedAt: Date())
        saved.duration = try AudioCompatibility.inspect(destination).duration
        saved.spotiLyricsFiles = spotiFiles
        if forceAAC { saved.isConvertedCopy = true }
        songs.append(saved)
        try persist()
        return saved
    }

    /// Records the album as a pending playlist. It is made when the user taps Compile pending
    /// playlists on Spotify's Local Files page, where Spotify's services are sure to be up.
    @discardableResult
    public func plan(album name: String, artists: [String], cover: Data?, releaseDate: Date? = nil, songs saved: [SavedSong]) async throws -> PlaylistPlan {
        let ids = saved.map(\.id).reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
        // The same album imported again is updated, not made a second time.
        if var existing = playlists.first(where: { Self.albumKey($0) == Self.albumKey(name: name, artists: artists) }) {
            existing.songIDs = ids + existing.songIDs.filter { !ids.contains($0) }
            if let cover { existing.coverFilename = try storeCover(cover, replacing: existing.coverFilename) }
            if let releaseDate { existing.releaseDate = releaseDate }
            if existing.status == .published { existing.status = .pending }
            existing.lastError = nil
            update(existing)
            return existing
        }
        var coverName: String?
        if let cover {
            let folder = supportFolder.appendingPathComponent("Covers", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            coverName = UUID().uuidString + (cover.starts(with: [137, 80, 78, 71]) ? ".png" : ".jpg")
            try cover.write(to: folder.appendingPathComponent(coverName!), options: .atomic)
        }
        var plan = PlaylistPlan(id: UUID(), name: name, artists: artists, coverFilename: coverName, songIDs: ids,
                                status: .pending, playlistURI: nil, lastError: nil, createdAt: Date())
        plan.releaseDate = releaseDate
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
                                  trackNumber: trackNumber, artwork: artwork, lyrics: lyrics, releaseDate: plan?.releaseDate)
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
        // Spotify knows a local file by its tags: take the old entry out of a made playlist, and
        // queue the edited song to be added.
        if var plan = self.album(of: song), let uri = plan.playlistURI, Self.identityChanged(song, edited) {
            if let old = plan.trackURIs?[song.id.uuidString] { try? await publisher.remove(tracks: [old], from: uri) }
            plan.trackURIs?[song.id.uuidString] = nil
            plan.status = .pending; plan.lastError = nil; update(plan)
        }
        try persist()
        return edited
    }
    static func identityChanged(_ a: SavedSong, _ b: SavedSong) -> Bool {
        a.title != b.title || a.artists != b.artists || a.album != b.album
    }

    /// Renames, re-credits, re-covers or re-dates an album, and sets its songs: `order` is the
    /// album's songs from now on, in order. Songs added leave the album they were on; songs left
    /// out become single songs again. Every song's tags are rewritten to match, and songs leaving
    /// a made playlist are taken out of it in Spotify. A nil cover keeps the album's cover.
    public func edit(_ plan: PlaylistPlan, name: String, artists: [String], cover: Data?, releaseDate: Date? = nil, order: [UUID]) async throws -> PlaylistPlan {
        guard var edited = playlists.first(where: { $0.id == plan.id }) else { throw ScoutError.message("This album is no longer in Scout.") }
        if let cover { edited.coverFilename = try storeCover(cover, replacing: edited.coverFilename) }
        if edited.playlistURI != nil, edited.spotifyName == nil { edited.spotifyName = edited.name }
        edited.name = name; edited.artists = artists; edited.releaseDate = releaseDate
        let known = Set(songs.map(\.id))
        let members = order.filter(known.contains).reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
        guard !members.isEmpty else { throw ScoutError.message("An album needs at least one song. Delete the album instead.") }
        let removed = edited.songIDs.filter { !members.contains($0) }
        let added = members.filter { !edited.songIDs.contains($0) }
        for id in removed { await takeOut(id, from: &edited) }
        // A song moving here leaves its old album (and that album's playlist).
        for id in added {
            guard var other = playlists.first(where: { $0.id != edited.id && $0.songIDs.contains(id) }) else { continue }
            await takeOut(id, from: &other)
            if other.songIDs.isEmpty { await delete(other, withSongs: false) } else { update(other) }
        }
        edited.songIDs = members
        if edited.playlistURI != nil, !added.isEmpty { edited.status = .pending; edited.lastError = nil }
        update(edited)
        let albumCover = cover ?? self.cover(of: edited)
        for (number, song) in songs(in: edited).enumerated() {
            _ = try await edit(song, title: song.title, artists: song.artists, album: name, trackNumber: number + 1,
                               lyrics: song.lyrics, cover: albumCover)
        }
        // Songs taken off the album are single songs again, keeping the cover they have.
        for song in songs.filter({ removed.contains($0.id) }) where album(of: song) == nil {
            _ = try await edit(song, title: song.title, artists: song.artists, album: song.title, trackNumber: 1, lyrics: song.lyrics, cover: nil)
        }
        return playlists.first { $0.id == plan.id } ?? edited
    }
    /// Takes a song off an album, and out of its playlist in Spotify when Scout knows the entry.
    private func takeOut(_ id: UUID, from plan: inout PlaylistPlan) async {
        plan.songIDs.removeAll { $0 == id }
        if let uri = plan.playlistURI, let track = plan.trackURIs?[id.uuidString] {
            try? await publisher.remove(tracks: [track], from: uri)
        }
        plan.trackURIs?[id.uuidString] = nil
    }

    // MARK: Deleting and duplicates

    /// Deletes a song: its audio, .lrc and spoti.pw lyrics. It is taken out of its album, and out
    /// of the album's playlist in Spotify when Scout knows its entry there; an album left with
    /// no songs is deleted too. Returns what couldn't be done in Spotify, if anything.
    @discardableResult
    public func delete(_ song: SavedSong) async -> String? {
        removeFiles(of: song, keepAudio: false)
        songs.removeAll { $0.id == song.id }
        var problem: String?
        for var plan in playlists where plan.songIDs.contains(song.id) {
            plan.songIDs.removeAll { $0 == song.id }
            if let uri = plan.playlistURI, let track = plan.trackURIs?[song.id.uuidString] {
                do { try await publisher.remove(tracks: [track], from: uri) }
                catch { problem = "\(song.title) is still in \(plan.name) in Spotify. Remove it there. (\(error.localizedDescription))" }
            }
            plan.trackURIs?[song.id.uuidString] = nil
            if plan.songIDs.isEmpty { if let note = await delete(plan, withSongs: false) { problem = note } }
            else { update(plan) }
        }
        try? persist()
        return problem
    }

    /// Deletes an album: its cover and, when it was made, its playlist in Spotify. Its songs are
    /// deleted too, or kept as single songs. Returns what couldn't be done in Spotify, if anything.
    @discardableResult
    public func delete(_ plan: PlaylistPlan, withSongs: Bool) async -> String? {
        guard let current = playlists.first(where: { $0.id == plan.id }) else { return nil }
        playlists.removeAll { $0.id == current.id }
        if let cover = coverURL(current) { try? FileManager.default.removeItem(at: cover) }
        var problem: String?
        if let uri = current.playlistURI {
            do { try await publisher.delete(playlist: uri) }
            catch { problem = "Spotify still has the playlist \(current.spotifyName ?? current.name). Remove it in Your Library. (\(error.localizedDescription))" }
        }
        if withSongs {
            for song in songs(in: current) { removeFiles(of: song, keepAudio: false) }
            songs.removeAll { current.songIDs.contains($0.id) }
        }
        try? persist()
        return problem
    }

    /// Merges what was imported more than once: the same song (name, artists and album) keeps
    /// one copy, and the same album (name and artists) keeps one entry, preferring what is
    /// already in Spotify, then the newest. A duplicate playlist Scout made in Spotify is removed.
    @discardableResult
    public func removeDuplicates() async -> Int {
        var removed = 0
        var replacement: [UUID: UUID] = [:]
        let inSpotify = Set(playlists.filter { $0.playlistURI != nil }.flatMap(\.songIDs))
        for group in Dictionary(grouping: songs, by: { Self.songKey($0) }).values where group.count > 1 {
            let keep = group.max { a, b in (inSpotify.contains(a.id) ? 1 : 0, a.savedAt) < (inSpotify.contains(b.id) ? 1 : 0, b.savedAt) }!
            for song in group where song.id != keep.id {
                if song.filename != keep.filename { removeFiles(of: song, keepAudio: false) }
                replacement[song.id] = keep.id; removed += 1
            }
        }
        if !replacement.isEmpty {
            songs.removeAll { replacement[$0.id] != nil }
            playlists = playlists.map { plan in
                var plan = plan
                plan.songIDs = plan.songIDs.map { replacement[$0] ?? $0 }.reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
                return plan
            }
        }
        for group in Dictionary(grouping: playlists, by: { Self.albumKey($0) }).values where group.count > 1 {
            let keep = group.max { a, b in (a.playlistURI != nil ? 1 : 0, a.createdAt) < (b.playlistURI != nil ? 1 : 0, b.createdAt) }!
            var merged = keep
            for plan in group where plan.id != keep.id {
                merged.songIDs += plan.songIDs.filter { !merged.songIDs.contains($0) }
                if merged.coverFilename == nil { merged.coverFilename = plan.coverFilename }
                else if let cover = coverURL(plan), plan.coverFilename != merged.coverFilename { try? FileManager.default.removeItem(at: cover) }
                playlists.removeAll { $0.id == plan.id }; removed += 1
                if let uri = plan.playlistURI { try? await publisher.delete(playlist: uri) }
            }
            if merged.playlistURI != nil, merged.songIDs.contains(where: { merged.trackURIs?[$0.uuidString] == nil }) { merged.status = .pending }
            update(merged)
        }
        if removed > 0 { try? persist() }
        return removed
    }

    /// What makes two imports the same song. A converter copy is never the same as its original.
    static func songKey(title: String, artists: [String], album: String, copy: Bool = false) -> String {
        ([title, Suggestions.joinArtists(artists), album].map(AlbumKey.normalize) + [copy ? "copy" : ""]).joined(separator: "\u{1f}")
    }
    static func songKey(_ song: SavedSong) -> String { songKey(title: song.title, artists: song.artists, album: song.album, copy: song.isConvertedCopy ?? false) }
    static func albumKey(name: String, artists: [String]) -> String {
        [name, Suggestions.joinArtists(artists)].map(AlbumKey.normalize).joined(separator: "\u{1f}")
    }
    static func albumKey(_ plan: PlaylistPlan) -> String { albumKey(name: plan.name, artists: plan.artists) }

    /// Removes a song's .lrc, spoti.pw lyrics and (unless kept) its audio.
    private func removeFiles(of song: SavedSong, keepAudio: Bool) {
        if !keepAudio { try? FileManager.default.removeItem(at: fileURL(song)) }
        try? FileManager.default.removeItem(at: fileURL(song).deletingPathExtension().appendingPathExtension("lrc"))
        for name in song.spotiLyricsFiles ?? [] { try? FileManager.default.removeItem(at: spotiLyricsFolder.appendingPathComponent(name)) }
    }
    private func storeCover(_ cover: Data, replacing old: String?) throws -> String {
        let folder = supportFolder.appendingPathComponent("Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = UUID().uuidString + (cover.starts(with: [137, 80, 78, 71]) ? ".png" : ".jpg")
        try cover.write(to: folder.appendingPathComponent(name), options: .atomic)
        if let old { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
        return name
    }

    /// Albums not yet made into playlists.
    public var waiting: [PlaylistPlan] { playlists.filter { $0.status != .published } }
    /// Compile pending playlists: makes every waiting album, one after another, and says how it went.
    /// A create Spotify never confirmed is only repeated on the second tap, after the user was told
    /// to check Your Library, so no duplicate playlists.
    public func compileWaiting() async -> (made: [PlaylistPlan], failed: [PlaylistPlan]) {
        forgetMissingFiles()
        await removeDuplicates()
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
