import Foundation
import AVFoundation

@MainActor final class AudioFileConverter: ObservableObject {
    struct Item: Identifiable {
        let id: UUID
        var title: String
        var duration: Double?
        var format: String
        var status: String
        var saved: SavedSong?
    }
    @Published private(set) var items: [Item] = []
    @Published private(set) var busy = false
    let library: ScoutLibrary
    private var songs: [UUID: DownloadedSong] = [:]
    private let work = FileManager.default.temporaryDirectory.appendingPathComponent("Scout-convert-" + UUID().uuidString)
    var canConvert: Bool { !busy && items.contains { $0.saved == nil && songs[$0.id] != nil } }

    init(library: ScoutLibrary) { self.library = library }
    deinit { try? FileManager.default.removeItem(at: work) }

    func add(_ urls: [URL]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        for url in urls {
            let id = UUID(), name = url.deletingPathExtension().lastPathComponent
            items.append(Item(id: id, title: name, format: "Reading audio…", status: "Checking file"))
            let index = items.count - 1
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let folder = work
                let normalized = try await Task.detached(priority: .userInitiated) {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 1_000_000_000 else { throw ScoutError.message("File exceeds the 1 GB conversion limit.") }
                    return try AudioCompatibility.normalizedCopy(url, into: folder)
                }.value
                let info = try AudioCompatibility.inspect(normalized)
                var song = await DownloadedSong.make(file: normalized, source: nil, artwork: nil)
                // Scout's own manifest can restore metadata even if an older malformed file cannot expose its tags.
                let previous = library.songs.first { library.fileURL($0).resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }
                song.taggedTitle = song.taggedTitle ?? previous?.title ?? name
                song.taggedArtist = song.taggedArtist ?? previous.map { Suggestions.joinArtists($0.artists) }
                song.taggedAlbum = song.taggedAlbum ?? previous?.album
                song.taggedLyrics = song.taggedLyrics ?? previous?.lyrics
                if song.taggedLyrics == nil {
                    song.taggedLyrics = try? String(contentsOf: url.deletingPathExtension().appendingPathExtension("lrc"), encoding: .utf8)
                }
                songs[id] = song
                items[index].title = song.taggedTitle ?? name
                items[index].duration = info.duration
                items[index].format = Self.format(info.codec)
                items[index].status = "Ready"
            } catch { items[index].format = "Unreadable audio"; items[index].status = error.localizedDescription }
        }
    }

    func convert() async {
        guard canConvert else { return }
        busy = true
        defer { busy = false }
        for index in items.indices where items[index].saved == nil {
            guard let song = songs[items[index].id] else { continue }
            items[index].status = "Converting to AAC…"
            do {
                let saved = try await library.save(SongDraft(song: song), lyrics: song.taggedLyrics,
                                                   lyricsSource: song.taggedLyrics == nil ? nil : "Converted file", forceAAC: true)
                items[index].saved = saved
                items[index].duration = saved.duration
                items[index].status = "Saved as \(saved.filename)"
                items[index].format = "AAC · M4A"
            } catch { items[index].status = error.localizedDescription }
        }
    }

    private static func format(_ codec: AudioFormatID) -> String {
        switch codec {
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatAppleLossless: return "Apple Lossless"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatLinearPCM: return "PCM audio"
        default: return "Audio"
        }
    }
}
