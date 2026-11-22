import Foundation
import AVFoundation

/// A file Scout has fetched (or the user picked), staged privately until it is saved.
public struct DownloadedSong: Identifiable, Hashable {
    public let id = UUID()
    public var file: URL
    public var source: ScoutTrack?
    /// What the file's own tags say, offered as suggestions.
    public var taggedTitle: String?
    public var taggedArtist: String?
    public var taggedAlbum: String?
    public var taggedLyrics: String?
    public var artwork: Data?
    public var embeddedArtwork: Data?
    public var duration: Double

    public static var stagingRoot: URL { FileManager.default.temporaryDirectory.appendingPathComponent("ScoutStaging", isDirectory: true) }

    public init(file: URL, source: ScoutTrack?, taggedTitle: String? = nil, taggedArtist: String? = nil, taggedAlbum: String? = nil,
                taggedLyrics: String? = nil, artwork: Data? = nil, embeddedArtwork: Data? = nil, duration: Double = 0) {
        self.file = file; self.source = source; self.taggedTitle = taggedTitle; self.taggedArtist = taggedArtist; self.taggedAlbum = taggedAlbum
        self.taggedLyrics = taggedLyrics; self.artwork = artwork; self.embeddedArtwork = embeddedArtwork; self.duration = duration
    }

    /// Reads the file's tags and length so every later step has something to suggest.
    public static func make(file: URL, source: ScoutTrack?, artwork: Data?) async -> DownloadedSong {
        let asset = AVURLAsset(url: file)
        var song = DownloadedSong(file: file, source: source, artwork: artwork)
        if let length = try? await asset.load(.duration).seconds, length.isFinite { song.duration = length }
        let items = (try? await asset.load(.commonMetadata)) ?? []
        func text(_ identifier: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first else { return nil }
            let value = try? await item.load(.stringValue)
            return value.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        song.taggedTitle = await text(.commonIdentifierTitle)
        song.taggedArtist = await text(.commonIdentifierArtist)
        song.taggedAlbum = await text(.commonIdentifierAlbumName)
        if let art = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first {
            song.embeddedArtwork = try? await art.load(.dataValue)
        }
        if song.embeddedArtwork.flatMap(CoverArtwork.image) == nil {
            song.embeddedArtwork = await Task.detached(priority: .userInitiated) { CoverArtwork.embedded(in: file) }.value
        }
        // Lyrics live outside the common keys (USLT / ©lyr).
        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
        for format in formats {
            let all = (try? await asset.loadMetadata(for: format)) ?? []
            for item in all where [.id3MetadataUnsynchronizedLyric, .iTunesMetadataLyrics].contains(item.identifier) {
                if let value = try? await item.load(.stringValue), !value.isEmpty { song.taggedLyrics = value }
            }
        }
        return song
    }
    public static func == (a: DownloadedSong, b: DownloadedSong) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Everything chosen for one song across the steps.
public struct SongDraft: Identifiable, Equatable {
    public var id: UUID { song.id }
    public var song: DownloadedSong
    public var title: String
    public var artists: [String]
    public var album: String
    public var trackNumber: Int = 1
    public var cover: Data?
    public var lyrics: LyricsChoice = .none
    /// Measure each word's time from the audio when the chosen lyrics are only line-timed.
    public var timeWords = true

    public init(song: DownloadedSong) {
        self.song = song
        title = song.source?.title ?? song.taggedTitle ?? song.file.deletingPathExtension().lastPathComponent
        artists = Suggestions.splitArtists(song.source?.artist ?? song.taggedArtist ?? "")
        album = song.source?.album ?? song.taggedAlbum ?? ""
        cover = song.embeddedArtwork ?? song.artwork
    }
    public var artistText: String { Suggestions.joinArtists(artists) }
}

public enum LyricsChoice: Equatable {
    case none
    case text(String, source: String)
    case generate
    public var isChosen: Bool { if case .none = self { return false }; return true }
}

/// Writes title, artists, album, number, cover and lyrics into the file itself, so Spotify's
/// local-files scanner and spoti.pw's Edit Info both read the same details.
public enum TagWriter {
    public struct Tags {
        public var title: String
        public var artist: String
        public var album: String
        public var albumArtist: String
        public var trackNumber: Int
        public var artwork: Data?
        public var lyrics: String?
        public var releaseDate: Date?
        public init(title: String, artist: String, album: String, albumArtist: String, trackNumber: Int, artwork: Data?, lyrics: String?, releaseDate: Date? = nil) {
            self.title = title; self.artist = artist; self.album = album; self.albumArtist = albumArtist
            self.trackNumber = trackNumber; self.artwork = artwork; self.lyrics = lyrics; self.releaseDate = releaseDate
        }
        /// "2011-08-08", the form both ID3 (TDRC) and MP4 (©day) take.
        var dateText: String? { releaseDate.map { $0.formatted(.iso8601.year().month().day().dateSeparator(.dash)) } }
    }
    /// Real MP3 stays MP3; everything else becomes Spotify-compatible AAC in M4A.
    public static func outputExtension(for source: URL) -> String {
        (try? AudioCompatibility.envelope(source).ext) == "mp3" ? "mp3" : "m4a"
    }
    public static func write(_ tags: Tags, from source: URL, to destination: URL, forceAAC: Bool = false) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("Scout-tags-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let prepared = try await Task.detached(priority: .userInitiated) {
            let normalized = try AudioCompatibility.normalizedCopy(source, into: work)
            return (normalized, try AudioCompatibility.inspect(normalized))
        }.value
        if prepared.1.codec == kAudioFormatMPEGLayer3 && !forceAAC {
            try await Task.detached(priority: .userInitiated) { try writeMP3(tags, from: prepared.0, to: destination) }.value
            _ = try AudioCompatibility.inspect(destination)
            try await verifyArtwork(tags.artwork, in: destination)
            return
        }
        let input: URL
        if !forceAAC, prepared.1.codec == kAudioFormatMPEG4AAC, prepared.0.pathExtension == "m4a",
           [44_100.0, 48_000.0].contains(prepared.1.rate), prepared.1.channels <= 2 {
            input = prepared.0
        } else {
            input = work.appendingPathComponent("compatible.m4a")
            try await Task.detached(priority: .userInitiated) { try AudioCompatibility.encodeAAC(from: prepared.0, to: input) }.value
        }
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: input), presetName: AVAssetExportPresetPassthrough) else {
            throw ScoutError.message("This audio format can't be tagged.")
        }
        func item(_ identifier: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
            let item = AVMutableMetadataItem(); item.identifier = identifier; item.value = value; return item
        }
        let textTags: [(AVMetadataIdentifier, String)] = [(.commonIdentifierTitle, tags.title), (.commonIdentifierArtist, tags.artist),
                                                        (.commonIdentifierAlbumName, tags.album), (.iTunesMetadataAlbumArtist, tags.albumArtist)]
        var metadata = textTags.filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { item($0.0, $0.1 as NSString) }
        if let lyrics = tags.lyrics, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { metadata.append(item(.iTunesMetadataLyrics, lyrics as NSString)) }
        if let date = tags.dateText { metadata.append(item(.iTunesMetadataReleaseDate, date as NSString)) }
        if tags.trackNumber > 0 {
            let n = tags.trackNumber
            metadata.append(item(.iTunesMetadataTrackNumber, Data([0, 0, UInt8((n >> 8) & 255), UInt8(n & 255), 0, 0, 0, 0]) as NSData))
        }
        if let data = tags.artwork {
            guard let artwork = CoverArtwork.image(data) else { throw ScoutError.message("The selected cover is not a readable image.") }
            let cover = AVMutableMetadataItem()
            cover.identifier = .iTunesMetadataCoverArt
            cover.dataType = artwork.metadataType
            cover.value = artwork.data as NSData
            metadata.append(cover)
        }
        export.metadata = metadata
        try await export.export(to: destination, as: .m4a)
        let result = try AudioCompatibility.inspect(destination)
        guard result.codec == kAudioFormatMPEG4AAC, abs(result.duration - prepared.1.duration) < max(1, prepared.1.duration * 0.02) else {
            throw ScoutError.message("The converted audio could not be verified. The original file has been kept.")
        }
        try await verifyArtwork(tags.artwork, in: destination)
    }
    private static func verifyArtwork(_ data: Data?, in file: URL) async throws {
        guard let data, let expected = CoverArtwork.image(data) else { return }
        let saved = await DownloadedSong.make(file: file, source: nil, artwork: nil)
        guard saved.embeddedArtwork == expected.data else {
            throw ScoutError.message("The cover could not be embedded in the converted file. The original file has been kept.")
        }
    }
    nonisolated static func writeMP3(_ tags: Tags, from source: URL, to destination: URL) throws {
        func sync(_ value: Int) -> Data { Data([UInt8((value >> 21) & 127), UInt8((value >> 14) & 127), UInt8((value >> 7) & 127), UInt8(value & 127)]) }
        func frame(_ key: String, _ data: Data) -> Data { Data(key.utf8) + sync(data.count) + Data([0, 0]) + data }
        var frames = Data()
        for (key, text) in [("TIT2", tags.title), ("TPE1", tags.artist), ("TALB", tags.album), ("TPE2", tags.albumArtist), ("TRCK", String(tags.trackNumber)),
                            ("TDRC", tags.dateText ?? "")] where !text.isEmpty {
            frames += frame(key, Data([3]) + Data(text.utf8))
        }
        if let lyrics = tags.lyrics { frames += frame("USLT", Data([3]) + Data("eng".utf8) + Data([0]) + Data(lyrics.utf8)) }
        if let data = tags.artwork {
            guard let artwork = CoverArtwork.image(data) else { throw ScoutError.message("The selected cover is not a readable image.") }
            frames += frame("APIC", Data([3]) + Data(artwork.mime.utf8) + Data([0, 3, 0]) + artwork.data)
        }
        guard frames.count < 0x0fffffff else { throw ScoutError.message("The cover or lyrics are too large for an MP3 tag.") }
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        let header = try input.read(upToCount: 10) ?? Data()
        var offset: UInt64 = 0
        if header.count == 10 && header.prefix(3) == Data("ID3".utf8) {
            let bytes = [UInt8](header)
            guard (2...4).contains(bytes[3]), bytes[6...9].allSatisfy({ $0 < 128 }) else { throw ScoutError.message("The MP3 has an unsupported tag header.") }
            offset = UInt64(10 + (Int(bytes[6]) << 21) + (Int(bytes[7]) << 14) + (Int(bytes[8]) << 7) + Int(bytes[9]))
            if bytes[3] == 4 && bytes[5] & 0x10 != 0 { offset += 10 }
        }
        let length = try input.seekToEnd()
        guard offset < length else { throw ScoutError.message("The MP3's tag runs past its audio.") }
        try input.seek(toOffset: offset)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw ScoutError.message("Could not create the audio file.") }
        let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
        try output.write(contentsOf: Data("ID3".utf8) + Data([4, 0, 0]) + sync(frames.count) + frames)
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { try output.write(contentsOf: chunk) }
    }
}
