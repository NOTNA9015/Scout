import Foundation

public enum ScoutError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

public enum AlbumKey {
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public struct LyricLine: Identifiable, Equatable {
    public var id: Int
    public var time: Double?
    public var text: String
    public var words: [TimedLyricWord] = []
}

public enum LyricsParser {
    public static func parse(_ text: String) -> [LyricLine] {
        let regex = try! NSRegularExpression(pattern: #"\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        let offsetRegex = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#)
        var offset: Double = 0
        if let match = offsetRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) { offset = (Double(text[range]) ?? 0) / 1000 }
        var result: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
            if matches.isEmpty {
                let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty && !clean.hasPrefix("[") { result.append(.init(id: result.count, time: nil, text: clean)) }
                continue
            }
            let words = TimedLyricWord.parse(raw, offset: offset)
            let clean = regex.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "").replacingOccurrences(of: #"<\d+:\d{2}(?:[.:]\d{1,3})?>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            for match in matches {
                func value(_ index: Int) -> String { Range(match.range(at: index), in: raw).map { String(raw[$0]) } ?? "" }
                let fraction = value(3)
                let time = (Double(value(1)) ?? 0) * 60 + (Double(value(2)) ?? 0) + (Double(fraction) ?? 0) / pow(10, Double(fraction.count)) + offset
                result.append(.init(id: result.count, time: max(0, time), text: clean, words: words))
            }
        }
        if result.contains(where: { $0.time != nil }) {
            result = result.filter { $0.time != nil }.sorted { $0.time! < $1.time! }
        }
        return result.enumerated().map { .init(id: $0.offset, time: $0.element.time, text: $0.element.text, words: $0.element.words) }
    }
}

/// A user-supplied JSON index of tracks (Scout's custom sources).
public struct SourceManifest: Codable {
    public var name: String
    public var tracks: [ScoutTrack]
}

public struct ScoutTrack: Codable, Identifiable, Hashable {
    public var id: String { audioURL }
    public var title: String
    public var artist: String
    public var album: String
    public var trackNumber: Int?
    public var version: String?
    public var audioURL: String
    public var artworkURL: String?
    public var lyrics: String?
    public var sourceURL: String?
    public var duration: Double?
    public var audioMirrors: [String]?
    public init(title: String, artist: String, album: String, trackNumber: Int? = nil, version: String? = nil, audioURL: String,
                artworkURL: String? = nil, lyrics: String? = nil, sourceURL: String? = nil, duration: Double? = nil, audioMirrors: [String]? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.trackNumber = trackNumber; self.version = version
        self.audioURL = audioURL; self.artworkURL = artworkURL; self.lyrics = lyrics; self.sourceURL = sourceURL
        self.duration = duration
        self.audioMirrors = audioMirrors
    }
}

public enum AudioFormats {
    public static let extensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "alac", "mp4", "ogg", "opus"]
}
