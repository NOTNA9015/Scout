import Foundation
import CryptoKit

/// Where spoti.pw 0.51 keeps "lyrics of your own" for local files, matched to its compiled code:
///
///   Library/Application Support/spoti.pw/Lyrics/<key>.<lrc|ttml|txt>
///   key = lowercase hex SHA-256 of the track's URI (UTF-8), for spotify:local: URIs
///   URI = "spotify:local:" + enc(artist) + ":" + enc(album) + ":" + enc(title) + ":" + floor(seconds)
///   enc = form encoding of the first 200 UTF-8 bytes: A–Z a–z 0–9 - . _ ~ kept, space → +, else %XX
///
/// Saving one extension removes the other two for the same key, as spoti.pw's own import does.
public enum SpotiPWLyrics {
    public static let extensions = ["ttml", "lrc", "txt"]
    public static func folder(applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
        applicationSupport.appendingPathComponent("spoti.pw/Lyrics", isDirectory: true)
    }
    public static func encode(_ text: String) -> String {
        var out = ""
        for byte in Array(text.utf8).prefix(200) {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E: out.append(Character(UnicodeScalar(byte)))
            case 0x20: out.append("+")
            default: out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
    public static func localURI(artist: String, album: String, title: String, seconds: Int) -> String {
        "spotify:local:" + encode(artist) + ":" + encode(album) + ":" + encode(title) + ":" + String(seconds)
    }
    public static func key(_ uri: String) -> String {
        guard uri.hasPrefix("spotify:local:") else { return uri }
        return SHA256.hash(data: Data(uri.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// LRC when timed (spoti.pw's LRC reader also takes <mm:ss.xx> word tags), plain text otherwise.
    public static func fileExtension(for lyrics: String) -> String {
        if lyrics.contains("<tt") { return "ttml" }
        return LyricsParser.parse(lyrics).contains { $0.time != nil } ? "lrc" : "txt"
    }
    /// Writes the lyrics for every length Spotify may have measured (its whole seconds can be one
    /// off ours), and returns the files written.
    @discardableResult
    public static func write(_ lyrics: String, artist: String, album: String, title: String, duration: Double, into folder: URL = folder()) throws -> [String] {
        guard duration.isFinite, duration > 0 else { return [] }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = fileExtension(for: lyrics)
        let whole = Int(duration.rounded(.down))
        var written: [String] = []
        for seconds in Set([whole, whole - 1, whole + 1]).filter({ $0 > 0 }).sorted() {
            let key = key(localURI(artist: artist, album: album, title: title, seconds: seconds))
            for other in extensions where other != ext { try? FileManager.default.removeItem(at: folder.appendingPathComponent(key + "." + other)) }
            let name = key + "." + ext
            try lyrics.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
            written.append(name)
        }
        return written
    }
}
