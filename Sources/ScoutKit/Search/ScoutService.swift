import Foundation
import AVFoundation
import Combine

struct ScoutCollection: Identifiable, Decodable {
    var identifier: String
    var title: String
    var creator: Creator?
    var subject: Creator?
    var collection: Creator?
    var mediatype: String?
    var matchScore: Int?
    var matchNote: String?
    var id: String { identifier }
    var artist: String { creator?.text ?? "Unknown artist" }
    enum Creator: Decodable {
        case one(String), many([String])
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { self = .one(value) }
            else { self = .many((try? container.decode([String].self)) ?? []) }
        }
        var values: [String] { switch self { case .one(let v): return [v]; case .many(let v): return v } }
        var text: String { switch self { case .one(let v): return v; case .many(let v): return v.joined(separator: ", ") } }
    }
}
@MainActor public final class ScoutService: ObservableObject {
    public static let shared = ScoutService()
    @Published var collections: [ScoutCollection] = []
    @Published var tracks: [ScoutTrack] = []
    @Published var loading = false
    @Published var error: String?
    @Published var sourceName = "Internet Archive"
    @Published var tracker: ArtistTracker?
    @Published var selectedSource = "Internet Archive"
    @Published private(set) var previewTrackID: String?
    @Published private(set) var previewPosition: Double = 0
    @Published private(set) var previewDuration: Double = 0
    @Published private(set) var previewPlaying = false
    @Published private(set) var previewLoading = false
    @Published private(set) var previewProgress: Double? = 0
    @Published private(set) var previewStatus = ""
    private var indexedTracker: ArtistTracker?
    private var trackerRows: [(ScoutTrack, String)] = []
    private var trackerWarning: String?
    @Published var importStatus = ""
    @Published var showUncertainMatches = false
    private var activeQuery = MusicSearchQuery("")
    @Published var customSources: [String] = UserDefaults.standard.stringArray(forKey: "scout.sources") ?? []
    private var preview: AVPlayer?
    private var previewTask: Task<Void, Never>?
    private var previewObserver: Any?
    private var previewEndObserver: NSObjectProtocol?
    private var previewFolder: URL?
    private var previewGeneration = UUID()
    private let previewLoader: ((ScoutTrack, URL) async throws -> DownloadedSong)?
    private var generation = UUID()
    private let session: URLSession
    private let trackerCatalog: TrackerCatalog
    public init(session: URLSession? = nil, previewLoader: ((ScoutTrack, URL) async throws -> DownloadedSong)? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "Scout/1.0 (personal on-device music library)"]
        let session = session ?? URLSession(configuration: config)
        self.session = session
        self.previewLoader = previewLoader
        trackerCatalog = TrackerCatalog(session: session)
    }
    private func fetch<T: Decodable>(_ url: URL, as: T.Type) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw ScoutError.message("The source could not be reached. Try again later.") }
        guard data.count <= 20_000_000 else { throw ScoutError.message("This index is too large (20 MB maximum).") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func selectSource(_ source: String) {
        generation = UUID(); stopPreview()
        selectedSource = source; sourceName = source
        loading = false; error = nil; tracks = []; collections = []; tracker = nil
        indexedTracker = nil; trackerRows = []; trackerWarning = nil
    }

    /// Filtering a loaded tracker is local and immediate, including while the user types.
    @discardableResult func filterTracker(_ query: String, artist: String = "") -> Bool {
        guard let request = TrackerSearch.resolve(query, artist: artist, source: selectedSource),
              request.tracker == indexedTracker else { return false }
        tracks = trackerRows.filter { row in request.terms.allSatisfy(row.1.contains) }.map(\.0)
        if let previewTrackID, !tracks.contains(where: { $0.id == previewTrackID }) { stopPreview() }
        error = tracks.isEmpty ? "No audio links match this search in \(request.tracker.rawValue). Try another song title, era, or version." : trackerWarning
        return true
    }

    func search(_ query: String, artist: String = "", source requestedSource: String? = nil) async {
        let source = requestedSource ?? selectedSource
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trackerSearch = TrackerSearch.resolve(query, artist: artist, source: source)
        guard !query.isEmpty || trackerSearch != nil else { return }
        let token = UUID(); generation = token
        activeQuery=MusicSearchQuery(query,artist:artist)
        stopPreview()
        selectedSource = trackerSearch?.tracker.rawValue ?? source
        indexedTracker = nil; trackerRows = []; trackerWarning = nil
        loading = true; error = nil; tracks = []; collections = []; sourceName = source; tracker = trackerSearch?.tracker
        defer { if token == generation { loading = false } }
        do {
            if let trackerSearch {
                sourceName = trackerSearch.tracker.rawValue
                let result = try await trackerCatalog.load(trackerSearch.tracker)
                guard token == generation else { return }
                let rows = await Task.detached(priority: .userInitiated) {
                    result.tracks.map { ($0, MusicSearchQuery.normalize([$0.title, $0.album, $0.version ?? ""].joined(separator: " "))) }
                }.value
                guard token == generation else { return }
                trackerRows = rows; indexedTracker = trackerSearch.tracker; trackerWarning = result.warning
                filterTracker(query, artist: artist)
            } else if source != "Internet Archive" {
                guard let url = URL(string: source), url.scheme == "https" else { throw ScoutError.message("Source indexes must use HTTPS.") }
                let manifest = try await fetch(url, as: SourceManifest.self)
                guard token == generation else { return }
                sourceName = manifest.name
                let terms = MusicSearchQuery.normalize(activeQuery.release+" "+activeQuery.artist).split(separator: " ")
                tracks = manifest.tracks.filter { track in
                    let haystack = AlbumKey.normalize([track.title, track.artist, track.album, track.version ?? ""].joined(separator: " "))
                    return terms.allSatisfy { haystack.contains($0) }
                }
            } else {
                struct Response: Decodable { var response: Body; struct Body: Decodable { var docs: [ScoutCollection] } }
                var components = URLComponents(string: "https://archive.org/advancedsearch.php")!
                components.queryItems = [URLQueryItem(name: "q", value: activeQuery.archiveQuery), URLQueryItem(name: "output", value: "json"), URLQueryItem(name: "rows", value: "80"), URLQueryItem(name: "fl[]", value: "identifier,title,creator,subject,collection,mediatype")]
                let result = try await fetch(components.url!, as: Response.self)
                guard token == generation else { return }
                let search=activeQuery
                collections=result.response.docs.compactMap { candidate in
                    var item=candidate
                    let score=MusicMatch.score(query:search,title:item.title,creator:item.artist,subjects:item.subject?.values ?? [],collections:item.collection?.values ?? [],mediaType:item.mediatype)
                    guard score >= (showUncertainMatches ? 45 : 70) else{return nil}
                    item.matchScore=score
                    item.matchNote=score>=95 && !search.artist.isEmpty ? "Strong artist & album match" : score>=70 ? "Title match · check artist and version" : "Uncertain match · check before importing"
                    return item
                }.sorted { ($0.matchScore ?? 0)>($1.matchScore ?? 0) }
                if collections.isEmpty { self.error="No confident music match. Add the artist, try another title, or enable broader matches." }
            }
        } catch { if token == generation { self.error = error.localizedDescription } }
    }
    func open(_ collection: ScoutCollection) async {
        let token = UUID(); generation = token
        loading = true; error = nil; tracks = []
        defer { if token == generation { loading = false } }
        do {
            struct Metadata: Decodable {
                var files: [File]
                var metadata: Item?
                struct Item: Decodable { var creator: ScoutCollection.Creator?; var mediatype: String?; var title: String?; var subject: ScoutCollection.Creator?; var collection: ScoutCollection.Creator? }
                struct File: Decodable, ArchiveAudioFile {
                    var name: String; var title: String?; var creator: String?; var album: String?; var track: String?; var original: String?; var format: String?; var duration: Double?
                    enum CodingKeys: String, CodingKey { case name, title, creator, album, track, original, format, length }
                    init(from decoder: Decoder) throws {
                        let c = try decoder.container(keyedBy: CodingKeys.self)
                        name = try c.decode(String.self, forKey: .name)
                        title = try? c.decode(String.self, forKey: .title)
                        creator = try? c.decode(String.self, forKey: .creator)
                        album = try? c.decode(String.self, forKey: .album)
                        original = try? c.decode(String.self, forKey:.original)
                        format = try? c.decode(String.self, forKey:.format)
                        track = (try? c.decode(String.self, forKey: .track)) ?? (try? c.decode(Int.self, forKey: .track)).map(String.init)
                        duration = TrackTime.valid(try? c.decode(Double.self, forKey: .length)) ?? TrackTime.parse(try? c.decode(String.self, forKey: .length))
                    }
                }
            }
            let url = URL(string: "https://archive.org/metadata/")!.appendingPathComponent(collection.identifier)
            let metadata = try await fetch(url, as: Metadata.self)
            guard token == generation else { return }
            if let item=metadata.metadata {
                let score=MusicMatch.score(query:activeQuery,title:item.title ?? collection.title,creator:item.creator?.text ?? collection.artist,subjects:item.subject?.values ?? [],collections:item.collection?.values ?? [],mediaType:item.mediatype ?? collection.mediatype)
                guard score >= (showUncertainMatches ? 45 : 70) else {throw ScoutError.message("This item's metadata does not match the requested music and artist. Try another result.")}
            }
            let base = URL(string: "https://archive.org/download/")!.appendingPathComponent(collection.identifier)
            tracks = ArchiveAudio.songs(in: metadata.files).map { song in
                let file = song.details
                return ScoutTrack(title: file.title ?? URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent, artist: file.creator ?? metadata.metadata?.creator?.text ?? collection.artist, album: file.album ?? collection.title, trackNumber: file.track.flatMap { Int($0.split(separator:"/").first ?? "") }, audioURL: base.appendingPathComponent(song.download.name).absoluteString, artworkURL: "https://archive.org/services/img/\(collection.identifier)", sourceURL: "https://archive.org/details/\(collection.identifier)", duration: file.duration ?? song.download.duration, audioMirrors: song.fallback.map { [base.appendingPathComponent($0.name).absoluteString] })
            }
            tracks.sort { ($0.trackNumber ?? 0, $0.title) < ($1.trackNumber ?? 0, $1.title) }
            if tracks.isEmpty { error = "This result has no directly accessible music files." }
        } catch { if token == generation { self.error = error.localizedDescription } }
    }
    func preview(_ track: ScoutTrack) {
        if previewTrackID == track.id {
            if previewLoading { stopPreview() } else { togglePreview() }
            return
        }
        stopPreview()
        let previewToken = previewGeneration
        previewTrackID = track.id; previewLoading = true
        previewProgress = 0; previewStatus = "Downloading preview"
        previewDuration = TrackTime.valid(track.duration) ?? 0
        previewTask = Task {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Scout-preview-" + UUID().uuidString)
            var keep = false
            defer { if !keep { try? FileManager.default.removeItem(at: folder) } }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let song: DownloadedSong
                if let previewLoader { song = try await previewLoader(track, folder) }
                else {
                    song = try await DownloadedAudio.fetchPreview(track, session: session, into: folder) { [weak self] fraction, status in
                        guard let self, self.previewGeneration == previewToken, !Task.isCancelled else { return }
                        self.previewProgress = fraction; self.previewStatus = status
                    }
                }
                try Task.checkCancellation()
                guard previewGeneration == previewToken else { return }
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                let player = AVPlayer(url: song.file)
                preview = player; previewFolder = folder; keep = true
                previewDuration = song.duration; previewLoading = false; previewPlaying = true
                previewObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self, weak player] time in
                    Task { @MainActor in
                        guard let self, self.previewGeneration == previewToken else { return }
                        self.previewPosition = time.seconds.isFinite ? max(0, time.seconds) : 0
                        self.previewPlaying = (player?.rate ?? 0) > 0
                    }
                }
                previewEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.previewGeneration == previewToken else { return }
                        self.preview?.pause(); self.preview?.seek(to: .zero)
                        self.previewPosition = 0; self.previewPlaying = false
                    }
                }
                player.play()
            } catch is CancellationError {} catch {
                if !Task.isCancelled, previewGeneration == previewToken { stopPreview(); self.error = error.localizedDescription }
            }
        }
    }
    func togglePreview() {
        guard let preview, !previewLoading else { return }
        if previewPlaying { preview.pause(); previewPlaying = false }
        else { preview.play(); previewPlaying = true }
    }
    func seekPreview(to seconds: Double) {
        guard seconds.isFinite, let preview, !previewLoading else { return }
        previewPosition = min(max(0, seconds), previewDuration)
        preview.seek(to: CMTime(seconds: previewPosition, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func stopPreview(matching trackID: String) { if previewTrackID == trackID { stopPreview() } }
    func stopPreview() {
        previewGeneration = UUID()
        previewTask?.cancel(); previewTask = nil; preview?.pause()
        if let previewObserver { preview?.removeTimeObserver(previewObserver) }
        if let previewEndObserver { NotificationCenter.default.removeObserver(previewEndObserver) }
        previewObserver = nil; previewEndObserver = nil; preview = nil
        if let previewFolder { try? FileManager.default.removeItem(at: previewFolder) }
        previewFolder = nil; previewTrackID = nil; previewPosition = 0; previewDuration = 0
        previewPlaying = false; previewLoading = false
        previewProgress = 0; previewStatus = ""
    }
    func addSource(_ address: String) throws {
        guard let url = URL(string: address), url.scheme == "https", url.host != nil else { throw ScoutError.message("Enter an HTTPS URL to a Scout JSON source index.") }
        if !customSources.contains(address) { customSources.append(address); UserDefaults.standard.set(customSources, forKey: "scout.sources") }
    }
    func removeSource(_ address: String) { customSources.removeAll { $0 == address }; UserDefaults.standard.set(customSources, forKey: "scout.sources") }
    /// Downloads to a private staging folder; nothing reaches Spotify until the user saves.
    /// The transfer itself runs on `DownloadManager`'s background session, so it keeps going when
    /// the app is backgrounded and reports progress for the bar.
    func download(_ items: [ScoutTrack]) async -> (songs: [DownloadedSong], failures: [String]) {
        stopPreview()
        return await DownloadManager.shared.perform(items)
    }
}

/// An audio file listed in an Archive item's metadata.
protocol ArchiveAudioFile { var name: String { get }; var original: String? { get }; var format: String? { get } }

/// Which file Scout downloads for each song of an Archive item.
///
/// The Archive keeps each upload (often FLAC) and derives MP3 copies from it. Files are grouped by
/// the upload they come from, so separately named versions stay apart. The MP3 is downloaded when
/// there is one: Spotify plays it as it is, while a FLAC is 4–5× larger and is converted to AAC on
/// the phone anyway. The best of the group (the upload, FLAC before M4A before MP3) still names the
/// song, and is the fallback if the MP3 fails.
enum ArchiveAudio {
    struct Song<File> { var download: File; var details: File; var fallback: File? }

    static func songs<File: ArchiveAudioFile>(in files: [File]) -> [Song<File>] {
        var groups: [String: [File]] = [:], order: [String] = []
        for file in files where AudioFormats.extensions.contains(ext(file.name)) {
            let key = URL(fileURLWithPath: file.original ?? file.name).deletingPathExtension().path
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(file)
        }
        return order.compactMap { key in
            guard let group = groups[key], let best = group.max(by: { quality($0) < quality($1) }) else { return nil }
            guard let mp3 = group.filter({ ext($0.name) == "mp3" }).max(by: { mp3Rank($0) < mp3Rank($1) }) else { return Song(download: best, details: best, fallback: nil) }
            return Song(download: mp3, details: best, fallback: mp3.name == best.name ? nil : best)
        }
    }

    private static func ext(_ name: String) -> String { URL(fileURLWithPath: name).pathExtension.lowercased() }
    private static func quality(_ file: ArchiveAudioFile) -> Int { (file.original == nil ? 100 : 0) + (["flac": 30, "m4a": 20, "mp3": 10][ext(file.name)] ?? 0) }
    /// An uploaded MP3 first, then the Archive's VBR copy, then the highest fixed bitrate ("128Kbps MP3").
    private static func mp3Rank(_ file: ArchiveAudioFile) -> Int {
        if file.original == nil { return 10_000 }
        let format = file.format ?? ""
        if format.localizedCaseInsensitiveContains("VBR") { return 1_000 }
        return Int(format.prefix { $0.isNumber }) ?? 0
    }
}
