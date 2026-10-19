import Foundation

/// One result from a catalog lookup: a name, its artists, the album and a cover.
public struct CatalogMatch: Identifiable, Hashable {
    public var id: String { source + ":" + title + ":" + artists.joined(separator: ",") + ":" + album }
    public var title: String
    public var artists: [String]
    public var album: String
    public var coverURL: URL?
    public var source: String
    public var duration: Double?
    public init(title: String, artists: [String], album: String, coverURL: URL?, source: String, duration: Double? = nil) {
        self.title = title; self.artists = artists; self.album = album; self.coverURL = coverURL; self.source = source
        self.duration = duration
    }
}

/// A cover option: either bytes already in hand or an address to fetch.
public struct CoverOption: Identifiable, Hashable {
    public var id: String
    public var label: String
    public var data: Data?
    public var url: URL?
    public init(id: String, label: String, data: Data? = nil, url: URL? = nil) { self.id = id; self.label = label; self.data = data; self.url = url }
}

public enum Suggestions {
    /// "A feat. B & C" → ["A", "B", "C"]. Keeps names that merely contain "and" intact.
    public static func splitArtists(_ text: String) -> [String] {
        let separators = [#"\s+feat\.?\s+"#, #"\s+ft\.?\s+"#, #"\s+featuring\s+"#, #"\s+x\s+"#, #"\s*&\s*"#, #"\s*,\s*"#, #"\s*;\s*"#, #"\s*/\s*"#, #"\s+with\s+"#]
        var parts = [text]
        for pattern in separators {
            parts = parts.flatMap { part in
                part.replacingOccurrences(of: pattern, with: "\u{1F}", options: [.regularExpression, .caseInsensitive]).components(separatedBy: "\u{1F}")
            }
        }
        var seen = Set<String>()
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "()[]"))) }
            .filter { !$0.isEmpty && seen.insert(AlbumKey.normalize($0)).inserted }
    }
    public static func joinArtists(_ artists: [String]) -> String { artists.joined(separator: ", ") }

    /// Featured artists named in a title: "Song (feat. B)" → ["B"].
    public static func featured(in title: String) -> [String] {
        guard let match = title.range(of: #"[\(\[](?:feat\.?|ft\.?|featuring|with)\s+([^\)\]]+)[\)\]]"#, options: [.regularExpression, .caseInsensitive]) else { return [] }
        let inner = String(title[match]).replacingOccurrences(of: #"^[\(\[](?:feat\.?|ft\.?|featuring|with)\s+"#, with: "", options: [.regularExpression, .caseInsensitive]).dropLast()
        return splitArtists(String(inner))
    }

    /// The title as given, then progressively cleaner versions of it: file-name noise,
    /// bracketed tags like [CDQ] / (Leak) / (prod. X), and featured credits removed.
    public static func nameVariants(_ raw: String) -> [String] {
        var options: [String] = []
        func add(_ value: String) {
            let clean = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_.")))
            if !clean.isEmpty, !options.contains(where: { AlbumKey.normalize($0) == AlbumKey.normalize(clean) }) { options.append(clean) }
        }
        add(raw)
        var text = raw.replacingOccurrences(of: "_", with: " ")
        text = text.replacingOccurrences(of: #"^\s*\d{1,3}\s*[-.)]\s*"#, with: "", options: .regularExpression)   // "03 - Song"
        add(text)
        let tags = #"\s*[\(\[](?:[^\)\]]*(?:leak|cdq|hq|lq|snippet|og|v\d|version|mix|master|unreleased|demo|prod\.?|instrumental|remaster)[^\)\]]*)[\)\]]"#
        add(text.replacingOccurrences(of: tags, with: "", options: [.regularExpression, .caseInsensitive]))
        add(text.replacingOccurrences(of: #"\s*[\(\[](?:feat\.?|ft\.?|featuring|with)\s+[^\)\]]+[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive]))
        add(text.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression))
        // "Artist - Song" file names: offer the part after the dash on its own.
        if let dash = text.range(of: " - ") { add(String(text[dash.upperBound...])) }
        return options
    }

    public static func nameOptions(for song: DownloadedSong, matches: [CatalogMatch]) -> [String] {
        var options: [String] = []
        for raw in [song.source?.title, song.taggedTitle, song.file.deletingPathExtension().lastPathComponent].compactMap({ $0 }) where !looksGenerated(raw) {
            for value in nameVariants(raw) where !options.contains(where: { AlbumKey.normalize($0) == AlbumKey.normalize(value) }) { options.append(value) }
        }
        for match in matches where !options.contains(where: { AlbumKey.normalize($0) == AlbumKey.normalize(match.title) }) { options.append(match.title) }
        return options
    }
    public static func artistOptions(for song: DownloadedSong, title: String, matches: [CatalogMatch]) -> [String] {
        var options: [String] = []
        func add(_ values: [String]) { for value in values where !options.contains(where: { AlbumKey.normalize($0) == AlbumKey.normalize(value) }) { options.append(value) } }
        add(splitArtists(song.source?.artist ?? "").filter { $0 != "Unknown artist" })
        add(splitArtists(song.taggedArtist ?? ""))
        add(featured(in: title)); add(featured(in: song.source?.title ?? "")); add(featured(in: song.taggedTitle ?? ""))
        for match in matches { add(match.artists) }
        return options
    }
    public static func coverOptions(for song: DownloadedSong, matches: [CatalogMatch]) -> [CoverOption] {
        var options: [CoverOption] = []
        if let data = song.embeddedArtwork { options.append(.init(id: "embedded", label: "In the file", data: data)) }
        if let data = song.artwork { options.append(.init(id: "source", label: "From the source", data: data)) }
        var seen = Set<URL>()
        for match in matches { if let url = match.coverURL, seen.insert(url).inserted { options.append(.init(id: url.absoluteString, label: match.album.isEmpty ? match.source : match.album, url: url)) } }
        return options
    }
    /// UUID-like staging names are not worth offering as a title.
    static func looksGenerated(_ text: String) -> Bool { UUID(uuidString: text) != nil }
}

/// Public catalog lookups for names, artists and covers. Every result is kept; the user picks.
public protocol CatalogSearching: Sendable {
    func songs(_ term: String) async -> [CatalogMatch]
    func albums(_ term: String) async -> [CatalogMatch]
    func artists(_ term: String) async -> [String]
}

public struct CatalogSearch: CatalogSearching {
    public init() {}
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()
    private func json(_ url: URL) async -> [String: Any]? {
        guard let (data, response) = await Net.get(url, session: Self.session), response.statusCode == 200, data.count < 5_000_000 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private func url(_ base: String, _ items: [String: String]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }
    public func songs(_ term: String) async -> [CatalogMatch] {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        async let apple = json(url("https://itunes.apple.com/search", ["term": term, "entity": "song", "limit": "25"]))
        async let deezer = json(url("https://api.deezer.com/search", ["q": term, "limit": "25"]))
        let a = (await apple)?["results"] as? [[String: Any]] ?? []
        let d = (await deezer)?["data"] as? [[String: Any]] ?? []
        return dedupe(a.compactMap(Self.apple) + d.compactMap(Self.deezer))
    }
    public func albums(_ term: String) async -> [CatalogMatch] {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        async let apple = json(url("https://itunes.apple.com/search", ["term": term, "entity": "album", "limit": "25"]))
        async let deezer = json(url("https://api.deezer.com/search/album", ["q": term, "limit": "25"]))
        let a = ((await apple)?["results"] as? [[String: Any]] ?? []).compactMap { row -> CatalogMatch? in
            guard let album = row["collectionName"] as? String else { return nil }
            return CatalogMatch(title: album, artists: Suggestions.splitArtists(row["artistName"] as? String ?? ""), album: album, coverURL: Self.large(row["artworkUrl100"] as? String), source: "Apple Music")
        }
        let d = ((await deezer)?["data"] as? [[String: Any]] ?? []).compactMap { row -> CatalogMatch? in
            guard let album = row["title"] as? String else { return nil }
            let artist = (row["artist"] as? [String: Any])?["name"] as? String ?? ""
            return CatalogMatch(title: album, artists: Suggestions.splitArtists(artist), album: album, coverURL: (row["cover_xl"] as? String).flatMap(URL.init(string:)), source: "Deezer")
        }
        return dedupe(a + d)
    }
    public func artists(_ term: String) async -> [String] {
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        async let apple = json(url("https://itunes.apple.com/search", ["term": term, "entity": "musicArtist", "limit": "15"]))
        async let deezer = json(url("https://api.deezer.com/search/artist", ["q": term, "limit": "15"]))
        let names = ((await apple)?["results"] as? [[String: Any]] ?? []).compactMap { $0["artistName"] as? String }
            + ((await deezer)?["data"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        var seen = Set<String>()
        return names.filter { seen.insert(AlbumKey.normalize($0)).inserted }
    }
    static func apple(_ row: [String: Any]) -> CatalogMatch? {
        guard let title = row["trackName"] as? String else { return nil }
        return CatalogMatch(title: title, artists: Suggestions.splitArtists(row["artistName"] as? String ?? ""), album: row["collectionName"] as? String ?? "",
                            coverURL: large(row["artworkUrl100"] as? String), source: "Apple Music", duration: (row["trackTimeMillis"] as? Double).map { $0 / 1000 })
    }
    static func deezer(_ row: [String: Any]) -> CatalogMatch? {
        guard let title = row["title"] as? String else { return nil }
        let artist = (row["artist"] as? [String: Any])?["name"] as? String ?? ""
        let album = row["album"] as? [String: Any]
        return CatalogMatch(title: title, artists: Suggestions.splitArtists(artist), album: album?["title"] as? String ?? "",
                            coverURL: (album?["cover_xl"] as? String).flatMap(URL.init(string:)), source: "Deezer", duration: row["duration"] as? Double)
    }
    /// Apple serves any size from the same path; ask for a full-size cover.
    static func large(_ address: String?) -> URL? { address.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "1200x1200bb")) } }
    private func dedupe(_ matches: [CatalogMatch]) -> [CatalogMatch] {
        var seen = Set<String>()
        return matches.filter { seen.insert(AlbumKey.normalize($0.title + "|" + $0.artists.joined(separator: ",") + "|" + $0.album)).inserted }
    }
}
