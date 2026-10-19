import Foundation

enum ArtistTracker: String, CaseIterable {
    case frankOcean = "Frank Ocean Tracker"
    case ye = "Ye Tracker"
    case kendrick = "Kendrick Lamar Tracker"

    var artist: String {
        switch self { case .frankOcean: return "Frank Ocean"; case .ye: return "Kanye West"; case .kendrick: return "Kendrick Lamar" }
    }
    var aliases: [String] {
        switch self {
        case .frankOcean: return ["frank ocean", "franck ocean"]
        case .ye: return ["kanye west", "kanye", "ye"]
        case .kendrick: return ["kendrick lamar", "kendrick", "k dot"]
        }
    }
    var url: URL {
        switch self {
        case .frankOcean: return URL(string: "https://franktracker.net/")!
        case .ye: return URL(string: "https://yetracker.net/")!
        case .kendrick: return URL(string: "https://docs.google.com/spreadsheets/d/1i4OQglDHiiqMDthqfUFPutGmpZzK7n63LaoWApqhQXI/preview")!
        }
    }
}

struct TrackerSearch {
    let tracker: ArtistTracker
    let terms: [String]

    /// A named source searches that artist; typing “ye tracker” also works from Archive.
    static func resolve(_ text: String, artist: String = "", source: String) -> TrackerSearch? {
        let normalized = MusicSearchQuery.normalize(text)
        let hasTracker = normalized.split(separator: " ").contains { $0 == "tracker" || $0 == "trackers" }
        let combined = " " + MusicSearchQuery.normalize(text + " " + artist) + " "
        let selected = ArtistTracker(rawValue: source)
        let named = (source == "Internet Archive" || selected != nil) && hasTracker ? ArtistTracker.allCases.first(where: { item in
            item.aliases.contains { combined.contains(" " + $0 + " ") }
        }) : nil
        guard let tracker = named ?? selected else { return nil }
        var filter = " " + normalized + " "
        if hasTracker {
            for alias in tracker.aliases { filter = filter.replacingOccurrences(of: " " + alias + " ", with: " ") }
        }
        let terms = filter.split(separator: " ").map(String.init).filter { !["tracker", "trackers"].contains($0) }
        return TrackerSearch(tracker: tracker, terms: terms)
    }

    func filter(_ tracks: [ScoutTrack]) -> [ScoutTrack] {
        tracks.filter { track in
            let haystack = MusicSearchQuery.normalize([track.title, track.album, track.version ?? ""].joined(separator: " "))
            return terms.allSatisfy(haystack.contains)
        }
    }
}

/// Public spreadsheet previews preserve hyperlinks, unlike CSV exports. No account or API key.
actor TrackerCatalog {
    struct Result { var tracks: [ScoutTrack]; var warning: String? }
    private let session: URLSession
    private var cache: [ArtistTracker: (date: Date, tracks: [ScoutTrack])] = [:]

    init(session: URLSession) { self.session = session }

    func load(_ tracker: ArtistTracker) async throws -> Result {
        if let cached = cache[tracker], Date().timeIntervalSince(cached.date) < 600 {
            return Result(tracks: cached.tracks)
        }
        let page = try await html(tracker.url)
        let sheets = TrackerHTML.sheets(in: page, relativeTo: tracker.url)
        guard !sheets.isEmpty else { throw ScoutError.message("\(tracker.rawValue) has changed or is unavailable. Try opening the tracker and search again later.") }
        var tracks: [ScoutTrack] = [], failed: [String] = []
        // Keep sheet order stable while fetching independent tabs together.
        let pages = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, sheet) in sheets.enumerated() {
                group.addTask { (index, try? await self.html(sheet.url)) }
            }
            var pages: [(Int, String?)] = []
            for await page in group { pages.append(page) }
            return pages.sorted { $0.0 < $1.0 }
        }
        for (index, page) in pages {
            guard let page else { failed.append(sheets[index].name); continue }
            let parsed = TrackerHTML.tracks(in: page, tracker: tracker)
            if parsed.isEmpty { failed.append(sheets[index].name) }
            tracks += parsed
        }
        guard !tracks.isEmpty else { throw ScoutError.message("\(tracker.rawValue) returned no supported audio links. The tracker may be unavailable or its format may have changed.") }
        var seen = Set<String>()
        tracks = tracks.filter { seen.insert($0.id).inserted }
        if failed.isEmpty { cache[tracker] = (Date(), tracks) }
        return Result(tracks: tracks, warning: failed.isEmpty ? nil : "Some tracker tabs could not be loaded: \(failed.joined(separator: ", ")). Search again to retry.")
    }

    private func html(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme == "https", data.count <= 20_000_000,
              let page = String(data: data, encoding: .utf8) else {
            throw ScoutError.message("The tracker could not be read. Try again later.")
        }
        return page
    }
}

enum TrackerHTML {
    struct Sheet { let name: String; let url: URL }
    private struct Cell { var text: String; var links: [String] }
    private static let rowPattern = regex(#"<tr\b[^>]*>(.*?)</tr>"#)
    private static let cellPattern = regex(#"<td\b([^>]*)>(.*?)</td>"#)
    private static let linkPattern = regex(#"\bhref\s*=\s*["']([^"']+)["']"#)
    private static let tagPattern = regex(#"<[^>]*>"#)
    private static let breakPattern = regex(#"<br\s*/?>|</(?:p|div)>"#)
    private static let entityPattern = regex(#"&(#x[0-9a-f]+|#[0-9]+|[a-z]+);"#)
    private static let colspanPattern = regex(#"colspan=["']?(\d+)"#)
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }
    private static func matches(_ regex: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func capture(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String {
        Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }

    static func sheets(in page: String, relativeTo base: URL) -> [Sheet] {
        let pattern = regex(#"items\.push\(\{name:\s*"((?:\\.|[^"\\])*)",\s*pageUrl:\s*"((?:\\.|[^"\\])*)""#)
        return matches(pattern, page).compactMap { match in
            guard let name = javascriptString(capture(match, 1, in: page)),
                  ["unreleased", "released"].contains(MusicSearchQuery.normalize(name)),
                  let address = javascriptString(capture(match, 2, in: page)),
                  let url = URL(string: address, relativeTo: base)?.absoluteURL, url.scheme == "https" else { return nil }
            return Sheet(name: name, url: url)
        }
    }

    private static func javascriptString(_ encoded: String) -> String? {
        let escaped = regex(#"\\x([0-9a-f]{2})"#).stringByReplacingMatches(in: encoded, range: NSRange(encoded.startIndex..., in: encoded), withTemplate: #"\\u00$1"#)
        return try? JSONDecoder().decode(String.self, from: Data(("\"" + escaped + "\"").utf8))
    }

    static func text(_ html: String) -> String {
        let breaks = breakPattern.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "\n")
        let plain = tagPattern.stringByReplacingMatches(in: breaks, range: NSRange(breaks.startIndex..., in: breaks), withTemplate: "")
        return entities(plain).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func entities(_ text: String) -> String {
        var result = text
        for match in matches(entityPattern, text).reversed() {
            let code = capture(match, 1, in: text)
            let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ", "ndash": "–", "mdash": "—", "rsquo": "’", "lsquo": "‘"]
            var value = named[code]
            if code.hasPrefix("#") {
                let hex = code.lowercased().hasPrefix("#x")
                if let number = UInt32(code.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(number) { value = String(scalar) }
            }
            if let value, let range = Range(match.range, in: result) { result.replaceSubrange(range, with: value) }
        }
        return result
    }

    static func tracks(in page: String, tracker: ArtistTracker) -> [ScoutTrack] {
        var tracks: [ScoutTrack] = [], columns: [String] = []
        for rowMatch in matches(rowPattern, page) {
            let row = capture(rowMatch, 1, in: page)
            var cells: [Cell] = []
            for match in matches(cellPattern, row) {
                let body = capture(match, 2, in: row)
                cells.append(Cell(text: text(body), links: matches(linkPattern, body).map { entities(capture($0, 1, in: body)) }))
                let attributes = capture(match, 1, in: row)
                if let span = matches(colspanPattern, attributes).first,
                   let count = Int(capture(span, 1, in: attributes)), count > 1 {
                    cells += Array(repeating: Cell(text: "", links: []), count: min(count - 1, 50))
                }
            }
            let headings = cells.map { MusicSearchQuery.normalize($0.text.components(separatedBy: .newlines).first ?? "") }
            if headings.contains("era") && headings.contains("name") { columns = headings; continue }
            guard !columns.isEmpty else { continue }
            func cell(_ name: String) -> Cell {
                guard let index = columns.firstIndex(of: name), index < cells.count else { return Cell(text: "", links: []) }
                return cells[index]
            }
            let title = cell("name").text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
            let type = cell("available length").text, quality = cell("quality").text
            guard !title.isEmpty, !["confirmed", "rumored", "rumoured", "not available"].contains(MusicSearchQuery.normalize(type)),
                  MusicSearchQuery.normalize(quality) != "not available" else { continue }
            let links = columns.enumerated().filter { $0.element == "link s" || $0.element == "link" || $0.element == "mirror link" }.flatMap { index, _ in
                index < cells.count ? cells[index].links : []
            }
            // A row can have mirrors; keep its preferred supported link, not duplicate songs.
            var seen = Set<String>()
            let audioLinks = links.compactMap { TrackerAudio.audioURL(for: $0)?.absoluteString }.filter { seen.insert($0).inserted }
            guard let first = audioLinks.first else { continue }
            tracks.append(ScoutTrack(title: title, artist: tracker.artist, album: cell("era").text,
                                     version: [type, quality].filter { !$0.isEmpty }.joined(separator: " · "),
                                     audioURL: first, sourceURL: links.first(where: { TrackerAudio.audioURL(for: $0)?.absoluteString == first }).flatMap { TrackerAudio.unwrap($0)?.absoluteString },
                                     duration: TrackTime.parse(cell("track length").text), audioMirrors: Array(audioLinks.dropFirst())))
        }
        return tracks
    }
}

enum TrackerAudio {
    static func unwrap(_ address: String) -> URL? {
        guard let url = URL(string: address), url.scheme == "https", url.host != nil else { return nil }
        if ["www.google.com", "google.com"].contains(url.host), url.path == "/url",
           let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" || $0.name == "url" })?.value {
            guard let unwrapped = URL(string: target), unwrapped.scheme == "https", unwrapped.host != nil else { return nil }
            return unwrapped
        }
        return url
    }

    static func audioURL(for address: String) -> URL? {
        guard let url = unwrap(address) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if ["pillows.su", "pillowcase.su"].contains(url.host), parts.count == 2, parts[0] == "f",
           parts[1].count == 32, parts[1].allSatisfy({ $0.isHexDigit }) {
            return URL(string: "https://api.pillows.su/api/get/" + parts[1])
        }
        if url.host == "imgur.gg", parts.count == 2, parts[0] == "f", parts[1].allSatisfy({ $0.isLetter || $0.isNumber }) { return url }
        if AudioFormats.extensions.contains(url.pathExtension.lowercased()) { return url }
        return nil
    }

    /// Imgur's share pages expose the audio URL in a standard <audio src> element.
    static func embeddedAudio(in page: String, relativeTo base: URL) -> URL? {
        let pattern = try! NSRegularExpression(pattern: #"<(?:audio|source)\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive)
        for match in pattern.matches(in: page, range: NSRange(page.startIndex..., in: page)) {
            guard let range = Range(match.range(at: 1), in: page),
                  let url = URL(string: TrackerHTML.entities(String(page[range])), relativeTo: base)?.absoluteURL,
                  url.scheme == "https", AudioFormats.extensions.contains(url.pathExtension.lowercased()) else { continue }
            return url
        }
        return nil
    }

    static func resolve(_ url: URL, session: URLSession) async throws -> URL {
        guard url.host == "imgur.gg", url.path.hasPrefix("/f/") else { return url }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 2_000_000,
              let page = String(data: data, encoding: .utf8), let audio = embeddedAudio(in: page, relativeTo: url) else {
            throw ScoutError.message("This tracker file is unavailable or has no audio download.")
        }
        return audio
    }
}
