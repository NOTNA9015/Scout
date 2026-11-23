import Foundation

/// Owns the audio downloads so they outlive the sheet that started them and keep running while
/// Spotify is in the background.
///
/// Two things make that work. The transfers use a *background* `URLSession`: iOS keeps those going
/// in its own daemon after the app is suspended, and hands the finished files back when the app is
/// next active. And the whole import is driven from here, a singleton, rather than from the
/// per-sheet `ScoutFlow` — so closing Scout's menu mid-download doesn't cancel anything, and
/// reopening it picks the download back up (see `ScoutRootView`).
///
/// Progress is published for a determinate bar. One import runs at a time. An Internet Archive file
/// comes in several byte ranges side by side (`SegmentedDownload`): the Archive limits each
/// connection, so this is about twice as fast. Songs download one at a time, each on all the
/// connections, but the next one starts while the one before is checked and converted.
@MainActor public final class DownloadManager: NSObject, ObservableObject {
    public static let shared = DownloadManager()

    // What the UI watches.
    @Published public private(set) var isRunning = false
    @Published public private(set) var fraction: Double = 0        // overall, 0…1
    @Published public private(set) var detail = ""                 // "Downloading 2 of 5 · Title"
    @Published public private(set) var total = 0
    @Published public private(set) var completed = 0
    /// Bytes of the file downloading now, and its size (0 while unknown).
    @Published public private(set) var received: Int64 = 0
    @Published public private(set) var expected: Int64 = 0

    /// False until the first bytes arrive: iOS can take a while to start a background transfer.
    public var started: Bool { fraction > 0 || received > 0 }
    /// "Starting…" until then, the overall percentage after.
    public var percentText: String { started ? "\(Int((fraction * 100).rounded()))%" : "Starting…" }
    /// The current file's bytes: "3.2 of 26.2 MB", or "Starting…" before any arrive.
    public var bytesText: String { Self.bytesText(received: received, expected: expected) }
    nonisolated static func bytesText(received: Int64, expected: Int64) -> String {
        guard received > 0 else { return "Starting…" }
        let mb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_000_000) }
        return expected > 0 ? "\(mb(received)) of \(mb(expected)) MB" : "\(mb(received)) MB"
    }

    /// A finished import no flow has taken yet. Kept so reopening the menu can resume where the
    /// user left off instead of downloading again.
    public struct Pending { public let mode: ScoutFlow.Mode; public let songs: [DownloadedSong]; public let failures: [String] }
    @Published public private(set) var pending: Pending?
    /// Bumped whenever `pending` becomes available, so the view has an Equatable change to watch.
    @Published public private(set) var pendingStamp: UUID?
    /// The mode of a download still in flight, for reattaching before it finishes.
    @Published public private(set) var runningMode: ScoutFlow.Mode?

    private var job: Task<Void, Never>?
    /// Per song downloading now (by its place in the import): what it is doing, and its file's
    /// size once known.
    private var status: [Int: String] = [:]
    private var sizes: [Int: Int64] = [:]
    /// Per transfer: the song it is for, and its bytes so far and expected.
    private var owners: [Int: Int] = [:]
    private var bytes: [Int: (written: Int64, expected: Int64)] = [:]
    /// Songs finished (saved or failed), and how far the rest are.
    private var finished = 0
    private var shares: [Int: Double] = [:]
    /// The song whose file is coming in now, whether the turn is taken (also while it is handed
    /// on), and the songs waiting for it.
    private var holder: Int?
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// One request per cover: an Archive item's songs share theirs.
    private var covers: [String: Task<Data?, Never>] = [:]

    private let delegate = DownloadSessionDelegate()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "dev.scout.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false          // user asked for this now, not when convenient
        // The ranges of a file come from one Archive server side by side.
        config.httpMaximumConnectionsPerHost = SegmentedDownload.maxParts
        config.httpAdditionalHeaders = ["User-Agent": "Scout/1.0 (personal on-device music library)"]
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    private let artwork: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "Scout/1.0 (personal on-device music library)"]
        return URLSession(configuration: config)
    }()

    private override init() {
        super.init()
        delegate.onProgress = { [weak self] task, written, total in
            Task { @MainActor in self?.record(task: task, written: written, expected: total) }
        }
    }

    // MARK: Running one import

    /// Starts an import unless one is already running. `operation` is the flow's own fetcher, so
    /// tests keep their stub and only the real path reaches `perform`.
    public func run(mode: ScoutFlow.Mode, operation: @escaping () async -> (songs: [DownloadedSong], failures: [String])) {
        guard job == nil, !isRunning else { return }
        isRunning = true; runningMode = mode; fraction = 0; completed = 0; total = 0; detail = ""; received = 0; expected = 0
        pending = nil
        job = Task { @MainActor in
            let result = await operation()
            job = nil; isRunning = false; runningMode = nil
            guard !Task.isCancelled else { return }
            pending = Pending(mode: mode, songs: result.songs, failures: result.failures)
            pendingStamp = UUID()
        }
    }
    /// Takes the finished import so it is delivered once.
    public func claim() -> Pending? { let value = pending; pending = nil; return value }
    /// Stops an in-flight download and clears everything (the "Stop" button).
    public func cancel() {
        job?.cancel(); job = nil
        isRunning = false; runningMode = nil; pending = nil; detail = ""; fraction = 0; completed = 0; total = 0; received = 0; expected = 0
    }

    // MARK: The downloads

    /// Songs in progress at once: while one is checked and converted, the next one's file comes in.
    static let songsAtOnce = 2

    /// Fetches each track to private staging, reporting progress as it goes, and returns them in
    /// the order given. Mirrors the validation the foreground path used; only the transfer moved
    /// to the background session.
    public func perform(_ items: [ScoutTrack]) async -> (songs: [DownloadedSong], failures: [String]) {
        let staging = DownloadedSong.stagingRoot
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        total = items.count; completed = 0; finished = 0
        status = [:]; sizes = [:]; owners = [:]; bytes = [:]; shares = [:]; covers = [:]; holder = nil
        refresh()
        var results = [Result<DownloadedSong, Error>?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, Result<DownloadedSong, Error>).self) { group in
            var next = 0
            func start() {
                guard next < items.count, !Task.isCancelled else { return }
                let index = next; next += 1
                group.addTask { await (index, self.song(items[index], at: index, into: staging)) }
            }
            for _ in 0..<Self.songsAtOnce { start() }
            for await (index, result) in group {
                results[index] = result
                finished += 1; completed = finished; status[index] = nil; shares[index] = nil; sizes[index] = nil
                for (task, owner) in owners where owner == index { owners[task] = nil; bytes[task] = nil }
                refresh()
                if case .failure(let error) = result, error is CancellationError { group.cancelAll(); break }
                start()
            }
        }
        covers = [:]; holder = nil; detail = ""
        var songs: [DownloadedSong] = [], failures: [String] = []
        for (index, result) in results.enumerated() {
            switch result {
            case .success(let song): songs.append(song)
            case .failure(let error) where error is CancellationError: failures.append("\(items[index].title): Cancelled")
            case .failure(let error): failures.append("\(items[index].title): \(error.localizedDescription)")
            case nil: break
            }
            if case .failure(let error) = result, error is CancellationError { break }
        }
        return (songs, failures)
    }

    /// One song: its audio and, meanwhile, its cover.
    private func song(_ item: ScoutTrack, at index: Int, into staging: URL) async -> Result<DownloadedSong, Error> {
        let cover = coverTask(item.artworkURL)
        do {
            var song = try await fetchAudio(item, into: staging, index: index)
            if let data = await cover?.value { song.artwork = data }
            return .success(song)
        } catch { return .failure(Task.isCancelled ? CancellationError() : error) }
    }
    private func coverTask(_ address: String?) -> Task<Data?, Never>? {
        guard let address, let url = URL(string: address), url.scheme == "https" else { return nil }
        if let known = covers[address] { return known }
        let session = artwork
        let task = Task { () -> Data? in
            guard let (data, _) = try? await session.data(from: url), data.count < 10_000_000 else { return nil }
            return data
        }
        covers[address] = task
        return task
    }

    private func fetchAudio(_ item: ScoutTrack, into staging: URL, index: Int) async throws -> DownloadedSong {
        var lastError: Error = ScoutError.message("No downloadable audio link.")
        var seen = Set<String>()
        let addresses = ([item.audioURL] + (item.audioMirrors ?? [])).filter { seen.insert($0).inserted }
        for (attempt, address) in addresses.enumerated() {
            do {
                try Task.checkCancellation()
                show(index, "\(attempt == 0 ? "Downloading" : "Trying mirror for") \(index + 1) of \(total) · \(item.title) · \(TrackTime.text(item.duration))")
                guard let url = URL(string: address), url.scheme == "https" else { throw ScoutError.message("Audio URL must use HTTPS.") }
                let audioURL = try await TrackerAudio.resolve(url, session: artwork)
                try Task.checkCancellation()
                restart(index)
                let (temp, http) = try await transfer(audioURL, for: index)
                defer { try? FileManager.default.removeItem(at: temp) }
                guard (200..<300).contains(http.statusCode) else { throw ScoutError.message("Download unavailable") }
                if let mime = http.mimeType, mime.hasPrefix("text/") || ["application/json", "application/pdf"].contains(mime) { throw ScoutError.message("This source returned a document instead of audio.") }
                let size = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1_000_000_000 else { throw ScoutError.message("File exceeds the 1 GB import limit.") }
                shares[index] = 0.9; refresh()
                return try await DownloadedAudio.prepare(temp, track: item, into: staging) { [weak self] duration in
                    guard let self else { return }
                    self.show(index, "Converting \(index + 1) of \(self.total) · \(item.title) · \(TrackTime.text(duration))")
                }
            } catch is CancellationError { throw CancellationError() }
            catch { if Task.isCancelled { throw CancellationError() }; lastError = error }
        }
        throw lastError
    }

    /// The file at `url` for song `index`, once the songs before it are in: an Archive file in
    /// ranges side by side, anything else whole.
    private func transfer(_ url: URL, for index: Int) async throws -> (URL, HTTPURLResponse) {
        let session = session, delegate = delegate
        var download = SegmentedDownload(fetch: { [weak self] request in
            try await delegate.download(request, in: session) { task in Task { @MainActor in self?.owners[task] = index } }
        }, open: SegmentedDownload.streaming(using: artwork) { [weak self] written in
            // The first range comes over the foreground session; it counts under a made-up transfer id.
            Task { @MainActor in
                guard let self, self.status[index] != nil else { return }
                self.owners[-1 - index] = index; self.record(task: -1 - index, written: written, expected: -1)
            }
        })
        download.sized = { [weak self] size in Task { @MainActor in self?.restart(index, size: size) } }
        await take(index)
        defer { give() }
        try Task.checkCancellation()
        return try await download.download(url)
    }
    /// One song's file at a time, in the order they asked. The turn passes straight to the next
    /// waiter, so no one else can take it in between.
    private func take(_ index: Int) async {
        if busy { await withCheckedContinuation { waiting.append($0) } } else { busy = true }
        holder = index; received = 0; expected = 0; refresh()
    }
    private func give() {
        holder = nil
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    // MARK: Progress

    private func show(_ index: Int, _ text: String) { status[index] = text; refresh() }
    /// A song starting over (a mirror, or a file fetched whole after its ranges failed).
    private func restart(_ index: Int, size: Int64? = nil) {
        for (task, owner) in owners where owner == index { bytes[task] = nil }
        sizes[index] = size; shares[index] = 0; refresh()
    }
    private func record(task: Int, written: Int64, expected: Int64) {
        guard let index = owners[task] else { return }
        bytes[task] = (written, expected)
        let (got, size) = progress(of: index)
        if size > 0 { shares[index] = min(1, Double(got) / Double(size)) * 0.9 }
        refresh()
    }
    /// Song `index`'s bytes so far over all its requests, and its size (0 while unknown). A range
    /// asked for twice counts twice, so the bytes stop at the size.
    private func progress(of index: Int) -> (received: Int64, size: Int64) {
        let mine = owners.filter { $0.value == index }.compactMap { bytes[$0.key] }
        let got = mine.reduce(0) { $0 + $1.written }
        let size = sizes[index] ?? (mine.contains { $0.expected <= 0 } ? 0 : mine.reduce(0) { $0 + $1.expected })
        return (size > 0 ? min(got, size) : got, size)
    }
    /// The bar from every song in progress; the bytes and the line of text from the one coming in.
    private func refresh() {
        guard total > 0 else { fraction = 0; return }
        fraction = min(1, (Double(finished) + shares.values.reduce(0, +)) / Double(total))
        if let holder { (received, expected) = progress(of: holder) }
        if let shown = holder ?? status.keys.min(), let text = status[shown] { detail = text }
    }
}
