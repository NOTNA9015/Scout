import Foundation
import SwiftUI

/// Gets audio for the chosen results. Scout's own downloader in the app, fixtures in tests.
@MainActor public protocol SongFetching: AnyObject {
    func fetch(_ items: [ScoutTrack]) async -> (songs: [DownloadedSong], failures: [String])
}
extension ScoutService: SongFetching {
    public func fetch(_ items: [ScoutTrack]) async -> (songs: [DownloadedSong], failures: [String]) { await download(items) }
}

/// One import, song or album, from finding the music to saving it.
@MainActor public final class ScoutFlow: ObservableObject {
    public enum Mode { case song, album }
    public enum Step: Hashable { case names, lyrics, artists, cover, album, saving, done }

    public let mode: Mode
    @Published public var basket: [ScoutTrack] = []
    @Published public var drafts: [SongDraft] = []
    @Published public var path: [Step] = []
    @Published public var page = 0                      // which song a per-song step shows
    @Published public var downloading = false
    @Published public var status = ""
    @Published public var failures: [String] = []
    @Published public var matches: [UUID: [CatalogMatch]] = [:]
    @Published public var lyricOptions: [UUID: [LyricCandidate]] = [:]
    @Published public var lyricsLoading: Set<UUID> = []
    @Published public var lyricsErrors: [UUID: String] = [:]
    // Listening: Scout transcribes each song to recommend lyrics and time words.
    @Published public var heard: [UUID: [TimedLyricWord]] = [:]
    @Published public var listening: [UUID: String] = [:]
    @Published public var listenErrors: [UUID: String] = [:]
    @Published public var scores: [UUID: [String: Double]] = [:]
    /// The generated lyrics per song: what was heard, with lines from the lyrics found where they were sung.
    @Published public var assemblies: [UUID: LyricAssembly.Result] = [:]
    /// Share of the heard words each found lyric accounts for in its own order.
    private var explained: [UUID: [String: Double]] = [:]
    /// Songs whose lyrics choice is still Scout's own pick (a user choice is never overridden).
    @Published public var autoPicked: Set<UUID> = []
    /// Songs where the user chose themselves, including "No lyrics".
    private var userPicked: Set<UUID> = []
    @Published public var askGenerate = false            // the "no lyrics found — generate?" prompt
    @Published public var locale = Locale(identifier: Locale.current.identifier)
    // Album details (album mode).
    @Published public var albumName = ""
    @Published public var albumArtists: [String] = []
    @Published public var albumCover: Data?
    /// When the album came out; written into the songs' tags.
    @Published public var albumDate: Date?
    @Published public var albumMatches: [CatalogMatch] = []
    // Result.
    @Published public var saved: [SavedSong] = []
    @Published public var plan: PlaylistPlan?
    @Published public var saveError: String?

    let fetcher: SongFetching
    let catalog: CatalogSearching
    let lyricsSearch: LyricsSearching
    let library: ScoutLibrary
    let listener: AudioListening
    private var saving: Task<Void, Never>?
    private var listenQueue: Task<Void, Never>?

    public init(mode: Mode, fetcher: SongFetching, catalog: CatalogSearching = CatalogSearch(), lyrics: LyricsSearching = LyricsSearch(),
                library: ScoutLibrary = .shared, listener: AudioListening = OnDeviceListener()) {
        self.mode = mode; self.fetcher = fetcher; self.catalog = catalog; self.lyricsSearch = lyrics; self.library = library; self.listener = listener
    }

    // MARK: Finding

    public func toggle(_ track: ScoutTrack) {
        if mode == .song { basket = basket.first?.id == track.id ? [] : [track]; return }
        if let index = basket.firstIndex(where: { $0.id == track.id }) { basket.remove(at: index) } else { basket.append(track) }
    }
    public func isSelected(_ track: ScoutTrack) -> Bool { basket.contains { $0.id == track.id } }

    /// Hands the basket to the persistent `DownloadManager` and marks this flow as downloading. The
    /// download runs there, not here, so it survives the menu being closed and the app going to the
    /// background; `ScoutRootView` opens the detail steps once it finishes (`deliver(_:)`).
    public func download() {
        guard !basket.isEmpty, !downloading, !DownloadManager.shared.isRunning else { return }
        downloading = true; failures = []
        let items = basket, fetcher = self.fetcher
        DownloadManager.shared.run(mode: mode) { await fetcher.fetch(items) }
    }
    /// Takes a finished download from the manager and opens the detail steps.
    public func deliver(_ pending: DownloadManager.Pending) {
        downloading = false; status = ""
        failures = pending.failures
        begin(with: pending.songs)
    }
    /// Starts the detail steps with songs already in hand (downloads or picked files).
    public func begin(with songs: [DownloadedSong]) {
        guard !songs.isEmpty else { return }
        drafts = songs.enumerated().map { index, song in var draft = SongDraft(song: song); draft.trackNumber = index + 1; return draft }
        page = 0
        prepareAlbumDefaults()
        for draft in drafts { Task { await loadMatches(for: draft.id, term: Self.term(draft)) }; Task { await loadLyrics(for: draft.id) } }
        listenAll()
        path = [.names]
    }

    // MARK: Suggestions

    static func term(_ draft: SongDraft) -> String {
        let name = Suggestions.nameVariants(draft.title).last ?? draft.title
        return ([name] + draft.artists.prefix(1)).joined(separator: " ")
    }
    public func loadMatches(for id: UUID, term: String) async {
        let found = await catalog.songs(term)
        var current = matches[id] ?? []
        for match in found where !current.contains(match) { current.append(match) }
        matches[id] = current
    }
    /// Searches with the name and artists as currently chosen, adding to what was already found.
    public func loadLyrics(for id: UUID, title: String? = nil) async {
        guard let draft = drafts.first(where: { $0.id == id }) else { return }
        lyricsLoading.insert(id); defer { lyricsLoading.remove(id) }
        var current = lyricOptions[id] ?? []
        // What came with the song is offered first.
        if let text = draft.song.source?.lyrics, !text.isEmpty, !current.contains(where: { $0.id == "source" }) {
            current.insert(.init(id: "source", source: "From the source", title: draft.title, artist: draft.artistText, duration: nil, text: text), at: 0)
        }
        if let text = draft.song.taggedLyrics, !text.isEmpty, !current.contains(where: { $0.id == "tagged" }) {
            current.insert(.init(id: "tagged", source: "In the file", title: draft.title, artist: draft.artistText, duration: nil, text: text), at: 0)
        }
        lyricOptions[id] = current
        do {
            let search = { try await self.lyricsSearch.candidates(title: title ?? draft.title, artists: draft.artists, duration: draft.song.duration) }
            // A second round after a pause before telling the user anything.
            let found: [LyricCandidate]
            do { found = try await search() } catch { try await Task.sleep(for: .seconds(3)); found = try await search() }
            lyricsErrors[id] = nil
            var merged = lyricOptions[id] ?? []
            for candidate in found where !merged.contains(where: { $0.id == candidate.id }) { merged.append(candidate) }
            lyricOptions[id] = merged
        } catch is CancellationError {}
        catch { lyricsErrors[id] = error.localizedDescription }
        rescore(id); applyQuick(id)
    }

    // MARK: Listening

    /// One song at a time, in order, so the first song's result arrives first.
    func listenAll() {
        let ids = drafts.map(\.id)
        listenQueue?.cancel()
        listenQueue = Task { for id in ids where heard[id] == nil { if Task.isCancelled { return }; await listen(id) } }
    }
    public func listen(_ id: UUID) async {
        guard let draft = drafts.first(where: { $0.id == id }) else { return }
        listenErrors[id] = nil; listening[id] = "Listening to your audio…"
        defer { listening[id] = nil }
        do {
            let words = try await listener.words(in: draft.song.file, duration: draft.song.duration, locale: locale) { text in
                Task { @MainActor in if self.listening[id] != nil { self.listening[id] = text } }
            }
            heard[id] = words
            rescore(id)
        } catch is CancellationError {}
        catch { listenErrors[id] = error.localizedDescription }
        applyQuick(id)
    }
    /// A retry: listen again from scratch.
    public func relisten(_ id: UUID) { heard[id] = nil; scores[id] = nil; assemblies[id] = nil; Task { await listen(id) } }
    /// The user picked another vocal language: everything is heard again, one song at a time.
    public func setLocale(_ value: Locale) {
        let changed = value.language.languageCode != locale.language.languageCode
        locale = value
        guard changed else { return }
        heard = [:]; scores = [:]; assemblies = [:]; listenErrors = [:]
        listenAll()
    }

    func rescore(_ id: UUID) {
        guard let words = heard[id], !words.isEmpty, let draft = drafts.first(where: { $0.id == id }) else { return }
        var options = lyricOptions[id] ?? []
        let pieces = options.filter { $0.id != "generated" }
        // The generated lyrics are pieced together again with every lyric found so far.
        let assembly = LyricAssembly.assemble(heard: words, pieces: pieces)
        assemblies[id] = assembly
        let earlier = options.first { $0.id == "generated" }
        options.removeAll { $0.id == "generated" }
        if !assembly.lines.isEmpty {
            let generated = LyricCandidate(id: "generated", source: Self.generatedSource(assembly, pieces: pieces), title: draft.title,
                                           artist: draft.artistText, duration: draft.song.duration, text: assembly.lrc)
            options.append(generated)
            // A choice of the earlier version moves to the new one.
            if let earlier, let index = drafts.firstIndex(where: { $0.id == id }), drafts[index].lyrics == .text(earlier.text, source: earlier.source) {
                drafts[index].lyrics = .text(generated.text, source: generated.source)
            }
        }
        lyricOptions[id] = options
        var result: [String: Double] = [:], explains: [String: Double] = [:]
        for candidate in pieces {
            let fit = LyricsMatch.fit(candidate, heard: words)
            result[candidate.id] = fit.score; explains[candidate.id] = fit.explained
        }
        explained[id] = explains
        scores[id] = result
        // Pre-select the recommendation unless the user has chosen something themselves.
        guard let index = drafts.firstIndex(where: { $0.id == id }), !userPicked.contains(id) else { return }
        if let best = recommended(id) { drafts[index].lyrics = .text(best.text, source: best.source); autoPicked.insert(id) }
        applyQuick(id)
    }

    static func generatedSource(_ assembly: LyricAssembly.Result, pieces: [LyricCandidate]) -> String {
        guard assembly.onlineLines > 0 else { return "Generated from your audio" }
        var names: [String] = []
        for id in assembly.sources { if let name = pieces.first(where: { $0.id == id })?.source, !names.contains(name) { names.append(name) } }
        return "Pieced from your audio and " + (names.isEmpty ? "lyrics online" : names.joined(separator: " & "))
    }

    // MARK: Quick setup (everything)

    /// On after Quick setup on the first step: every detail is Scout's best guess and the import
    /// is saved straight away.
    @Published public private(set) var quickAll = false
    public func quickSetupEverything() {
        quickAll = true; quickLyrics = true
        for index in drafts.indices {
            drafts[index].title = Self.quickName(drafts[index])
            drafts[index].artists = Self.quickArtists(drafts[index])
        }
        if mode == .album { albumArtists = quickAlbumArtists() }
        save()
    }
    /// The source's name without download tags ([CDQ], (Leak), v2…), a leading track number or a
    /// "(feat. …)" part (the featured artists go into the artists instead).
    static func quickName(_ draft: SongDraft) -> String {
        var text = (draft.song.source?.title ?? draft.title).replacingOccurrences(of: "_", with: " ")
        text = text.replacingOccurrences(of: #"^\s*\d{1,3}\s*[-.)]\s*"#, with: "", options: .regularExpression)
        let junk = #"\s*[\(\[][^\)\]]*(?:leak|cdq|hq|lq|snippet|\bog\b|\bv\d|unreleased|demo|prod\.?)[^\)\]]*[\)\]]"#
        text = text.replacingOccurrences(of: junk, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\s*[\(\[](?:feat\.?|ft\.?|featuring|with)\s+[^\)\]]+[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-_.")))
        return text.isEmpty ? draft.title : text
    }
    /// The source's artists, then anyone featured in the name.
    static func quickArtists(_ draft: SongDraft) -> [String] {
        var artists = draft.artists.filter { $0 != "Unknown artist" }
        for name in Suggestions.featured(in: draft.song.source?.title ?? draft.title) + Suggestions.featured(in: draft.title)
        where !artists.contains(where: { AlbumKey.normalize($0) == AlbumKey.normalize(name) }) { artists.append(name) }
        return artists.isEmpty ? draft.artists : artists
    }
    /// The artist most songs start with.
    func quickAlbumArtists() -> [String] {
        let firsts = drafts.compactMap(\.artists.first)
        guard let first = firsts.first else { return albumArtists }
        let best = Dictionary(grouping: firsts, by: { $0 }).max { a, b in a.value.count == b.value.count ? firsts.firstIndex(of: a.key)! > firsts.firstIndex(of: b.key)! : a.value.count < b.value.count }?.key
        return [best ?? first]
    }
    /// While saving: the catalog's spelling of the name, a cover when the song has none, the album's
    /// name and cover.
    func quickDetails() async {
        for index in drafts.indices {
            if Task.isCancelled { return }
            let id = drafts[index].id
            progress[id] = "Finding details…"
            if (matches[id] ?? []).isEmpty { await loadMatches(for: id, term: Self.term(drafts[index])) }
            let found = matches[id] ?? []
            if let match = found.first(where: { AlbumKey.normalize($0.title) == AlbumKey.normalize(drafts[index].title) }) { drafts[index].title = match.title }
            if drafts[index].cover == nil {
                for option in Suggestions.coverOptions(for: drafts[index].song, matches: found) {
                    if let data = await CoverLoader.data(option) { drafts[index].cover = data; break }
                }
            }
        }
        guard mode == .album else { return }
        if albumName.trimmingCharacters(in: .whitespaces).isEmpty {
            let albums = drafts.flatMap { matches[$0.id] ?? [] }.map(\.album).filter { !$0.isEmpty }
            albumName = Dictionary(grouping: albums, by: { AlbumKey.normalize($0) }).max { $0.value.count < $1.value.count }?.value.first ?? ""
        }
        if albumCover == nil { albumCover = drafts.compactMap(\.cover).first }
        if albumCover == nil, !albumName.isEmpty {
            await searchAlbums(([albumName] + albumArtists.prefix(1)).joined(separator: " "))
            for option in albumCoverOptions() { if let data = await CoverLoader.data(option) { albumCover = data; break } }
        }
        if albumDate == nil, !albumName.isEmpty {
            if albumDateOptions().isEmpty { await searchAlbums(([albumName] + albumArtists.prefix(1)).joined(separator: " ")) }
            albumDate = albumDateOptions().first
        }
    }

    // MARK: Quick setup (lyrics)

    /// On after Quick setup: every song the user hasn't chosen for gets its recommended lyrics, or
    /// lyrics generated from the audio when nothing matched well enough to be recommended.
    @Published public private(set) var quickLyrics = false
    public func quickSetup() {
        quickLyrics = true
        for draft in drafts { applyQuick(draft.id) }
        // Past the remaining lyrics pages and the "generate?" prompt, to the next step.
        promptedGenerate = true
        page = max(0, drafts.count - 1)
        next()
    }
    /// Decides one song once there is something to decide on; songs still being heard wait.
    func applyQuick(_ id: UUID) {
        guard quickLyrics, !userPicked.contains(id), let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        switch recommendation(id) {
        case .recommended(let best, _): drafts[index].lyrics = .text(best.text, source: best.source); autoPicked.insert(id)
        case .noneMatch, .unavailable: if !lyricsLoading.contains(id) { drafts[index].lyrics = .generate; autoPicked.insert(id) }
        case .waiting: break
        }
    }
    /// At saving: finish deciding a Quick setup song (search done, audio heard), generating if still undecided.
    func settleQuick(_ id: UUID) async {
        guard quickLyrics, !userPicked.contains(id) else { return }
        progress[id] = "Choosing lyrics…"
        while lyricsLoading.contains(id) && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(300)) }
        if heard[id] == nil && listenErrors[id] == nil { await listen(id) }
        applyQuick(id)
        if case .waiting = recommendation(id), let index = drafts.firstIndex(where: { $0.id == id }) { drafts[index].lyrics = .generate }
    }
    public enum Recommendation: Equatable { case waiting, recommended(LyricCandidate, Double), noneMatch, unavailable }
    public func recommendation(_ id: UUID) -> Recommendation {
        if listenErrors[id] != nil { return .unavailable }
        guard heard[id] != nil, let scores = scores[id] else { return .waiting }
        if let best = recommended(id) { return .recommended(best, best.id == "generated" ? assemblies[id]?.onlineShare ?? 0 : scores[best.id] ?? 0) }
        return .noneMatch
    }
    /// The best whole lyric, or the pieced-together one when this version's parts are arranged
    /// differently from every lyric found.
    func recommended(_ id: UUID) -> LyricCandidate? {
        let options = lyricOptions[id] ?? []
        let best = LyricsMatch.best(options.filter { $0.id != "generated" }, scores: scores[id] ?? [:])
        if let assembly = assemblies[id], let pieced = options.first(where: { $0.id == "generated" }),
           LyricsMatch.prefersAssembly(assembly, over: best, explained: best.flatMap { explained[id]?[$0.id] }) { return pieced }
        return best
    }
    /// A choice the user makes themselves.
    public func choose(_ choice: LyricsChoice, for id: UUID) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].lyrics = choice; autoPicked.remove(id); userPicked.insert(id)
    }
    /// True once a search finished, reached the service, and found nothing at all.
    public func lyricsNotFound(_ id: UUID) -> Bool {
        !lyricsLoading.contains(id) && lyricsErrors[id] == nil && (lyricOptions[id]?.isEmpty ?? false)
    }
    public func nameOptions(_ draft: SongDraft) -> [String] { Suggestions.nameOptions(for: draft.song, matches: matches[draft.id] ?? []) }
    public func artistOptions(_ draft: SongDraft) -> [String] { Suggestions.artistOptions(for: draft.song, title: draft.title, matches: matches[draft.id] ?? []) }
    public func coverOptions(_ draft: SongDraft) -> [CoverOption] { Suggestions.coverOptions(for: draft.song, matches: matches[draft.id] ?? []) }

    private func prepareAlbumDefaults() {
        guard mode == .album else { return }
        let albums = drafts.map(\.album).filter { !$0.isEmpty }
        albumName = Dictionary(grouping: albums, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? ""
        albumArtists = Array(drafts.flatMap(\.artists).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(3))
        albumCover = drafts.compactMap(\.cover).first
    }
    public func albumNameOptions() -> [String] {
        var options: [String] = []
        for value in drafts.map(\.album) + drafts.compactMap({ $0.song.source?.album }) + albumMatches.map(\.album) where !value.isEmpty {
            if !options.contains(where: { AlbumKey.normalize($0) == AlbumKey.normalize(value) }) { options.append(value) }
        }
        return options
    }
    /// Release dates the catalogs give for an album of this name, earliest first.
    public func albumDateOptions() -> [Date] {
        let name = AlbumKey.normalize(albumName)
        var days: [Date] = []
        for match in albumMatches where AlbumKey.normalize(match.album) == name {
            if let date = match.releaseDate, !days.contains(where: { Calendar.current.isDate($0, inSameDayAs: date) }) { days.append(date) }
        }
        return days.sorted()
    }
    public func albumCoverOptions() -> [CoverOption] {
        var options: [CoverOption] = [], seen = Set<String>()
        for (index, draft) in drafts.enumerated() {
            for data in [draft.cover, draft.song.embeddedArtwork, draft.song.artwork].compactMap({ $0 }) where seen.insert(String(data.hashValue)).inserted {
                options.append(.init(id: "song-\(index)-\(data.count)", label: draft.title, data: data))
            }
        }
        for match in albumMatches { if let url = match.coverURL, seen.insert(url.absoluteString).inserted { options.append(.init(id: url.absoluteString, label: match.album, url: url)) } }
        return options
    }
    public func searchAlbums(_ term: String) async {
        let found = await catalog.albums(term)
        for match in found where !albumMatches.contains(match) { albumMatches.append(match) }
    }

    // MARK: Steps

    /// The order the user asked for: song → name, artists, cover, lyrics; album → names,
    /// lyrics (then the generate prompt), artists, album name & cover.
    var order: [Step] { mode == .song ? [.names, .artists, .cover, .lyrics] : [.names, .lyrics, .artists, .album] }
    public var current: Step? { path.last }
    public var perSong: Bool { mode == .album && [.names, .lyrics, .artists].contains(current) }

    public func next() {
        if perSong && page + 1 < drafts.count { page += 1; return }
        guard let step = current, let index = order.firstIndex(of: step) else { return }
        if step == .lyrics && missingLyrics > 0 && !promptedGenerate { promptedGenerate = true; askGenerate = true; return }
        page = 0
        if index + 1 < order.count {
            let upcoming = order[index + 1]
            // Names and artists may have changed since the first search; look again with them.
            if upcoming == .lyrics { for draft in drafts { Task { await loadLyrics(for: draft.id) } } }
            path.append(upcoming)
        } else { save() }
    }
    public func back() {
        if perSong && page > 0 { page -= 1; return }
        if path.count > 1 { path.removeLast(); page = perSong ? max(0, drafts.count - 1) : 0 }
    }
    private var promptedGenerate = false
    /// Songs still without lyrics after the lyrics step.
    public var missingLyrics: Int { drafts.filter { !$0.lyrics.isChosen }.count }
    /// The prompt raised on its own when a single song's search found nothing; answering it
    /// sets the choice and stays on the step.
    private var promptAdvances = true
    public func promptForMissing() { promptAdvances = false; promptedGenerate = true; askGenerate = true }
    public func answerGenerate(_ yes: Bool) {
        if yes { for index in drafts.indices where !drafts[index].lyrics.isChosen { drafts[index].lyrics = .generate } }
        askGenerate = false
        if promptAdvances { next() }
        promptAdvances = true
    }

    // MARK: Saving

    @Published public var progress: [UUID: String] = [:]
    public func save() {
        guard saving == nil else { return }
        path.append(.saving)
        // Songs not heard yet are listened to as they are saved; never run two at once.
        listenQueue?.cancel()
        saving = Task {
            defer { saving = nil }
            saveError = nil; saved = []
            if quickAll { await quickDetails() }
            let albumTitle = mode == .album ? albumName.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let albumArtist = mode == .album ? Suggestions.joinArtists(albumArtists) : nil
            for index in drafts.indices {
                if Task.isCancelled { return }
                // Everything quick: look for lyrics again with the cleaned-up name first.
                if quickAll { progress[drafts[index].id] = "Looking for lyrics…"; await loadLyrics(for: drafts[index].id) }
                await settleQuick(drafts[index].id)
                var draft = drafts[index]
                if mode == .album { draft.trackNumber = index + 1; if let albumCover { draft.cover = albumCover } }
                let id = draft.id
                progress[id] = "Preparing…"
                do {
                    let lyrics = try await LyricsMaker.finalize(draft, locale: locale, heard: heard[id], pieces: (lyricOptions[id] ?? []).filter { $0.id != "generated" }, listener: listener) { text in
                        Task { @MainActor in self.progress[id] = text }
                    }
                    let source: String? = { switch draft.lyrics { case .text(_, let s): return s; case .generate: return "Generated on this iPhone"; case .none: return nil } }()
                    progress[id] = "Saving…"
                    let song = try await library.save(draft, lyrics: lyrics, lyricsSource: source, album: albumTitle, albumArtist: albumArtist,
                                                      releaseDate: mode == .album ? albumDate : nil)
                    saved.append(song); progress[id] = "Saved"
                    try? FileManager.default.removeItem(at: draft.song.file)
                } catch is CancellationError { progress[id] = "Cancelled"; return }
                catch { progress[id] = "Failed: " + error.localizedDescription; failures.append("\(draft.title): \(error.localizedDescription)") }
            }
            if mode == .album, !saved.isEmpty {
                plan = try? await library.plan(album: albumTitle?.isEmpty == false ? albumTitle! : "Untitled album", artists: albumArtists, cover: albumCover, releaseDate: albumDate, songs: saved)
            }
            if saved.isEmpty && !failures.isEmpty { saveError = failures.joined(separator: "\n") }
            path.append(.done)
        }
    }
    public func cancelSaving() { saving?.cancel() }
    /// Staged downloads the user walked away from.
    public func discard() { saving?.cancel(); listenQueue?.cancel(); for draft in drafts where saved.first(where: { $0.id == draft.id }) == nil { try? FileManager.default.removeItem(at: draft.song.file) } }

    // Album order (album step).
    public func move(from source: IndexSet, to destination: Int) { drafts.move(fromOffsets: source, toOffset: destination) }
}
