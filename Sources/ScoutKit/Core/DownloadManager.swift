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
/// Progress is published for a determinate bar. One import runs at a time; its songs download in
/// order, so a single "current file" fraction is all the UI needs.
@MainActor public final class DownloadManager: NSObject, ObservableObject {
    public static let shared = DownloadManager()

    // What the UI watches.
    @Published public private(set) var isRunning = false
    @Published public private(set) var fraction: Double = 0        // overall, 0…1
    @Published public private(set) var detail = ""                 // "Downloading 2 of 5 · Title"
    @Published public private(set) var total = 0
    @Published public private(set) var completed = 0

    /// A finished import no flow has taken yet. Kept so reopening the menu can resume where the
    /// user left off instead of downloading again.
    public struct Pending { public let mode: ScoutFlow.Mode; public let songs: [DownloadedSong]; public let failures: [String] }
    @Published public private(set) var pending: Pending?
    /// Bumped whenever `pending` becomes available, so the view has an Equatable change to watch.
    @Published public private(set) var pendingStamp: UUID?
    /// The mode of a download still in flight, for reattaching before it finishes.
    @Published public private(set) var runningMode: ScoutFlow.Mode?

    private var job: Task<Void, Never>?
    private var itemFraction: Double = 0
    private var currentIndex = 0

    private let delegate = DownloadSessionDelegate()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "dev.scout.downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false          // user asked for this now, not when convenient
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
        delegate.onProgress = { [weak self] value in
            Task { @MainActor in guard let self else { return }; self.itemFraction = value * 0.9; self.refreshFraction() }
        }
    }

    // MARK: Running one import

    /// Starts an import unless one is already running. `operation` is the flow's own fetcher, so
    /// tests keep their stub and only the real path reaches `perform`.
    public func run(mode: ScoutFlow.Mode, operation: @escaping () async -> (songs: [DownloadedSong], failures: [String])) {
        guard job == nil, !isRunning else { return }
        isRunning = true; runningMode = mode; fraction = 0; completed = 0; total = 0; itemFraction = 0; detail = ""
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
        isRunning = false; runningMode = nil; pending = nil; detail = ""; fraction = 0; itemFraction = 0; completed = 0; total = 0
    }

    // MARK: The downloads

    /// Fetches each track to private staging, in order, reporting progress as it goes. Mirrors the
    /// validation the foreground path used; only the transfer moved to the background session.
    public func perform(_ items: [ScoutTrack]) async -> (songs: [DownloadedSong], failures: [String]) {
        var songs: [DownloadedSong] = [], failures: [String] = []
        let staging = DownloadedSong.stagingRoot
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        total = items.count; completed = 0
        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            currentIndex = index; itemFraction = 0; refreshFraction()
            detail = "Downloading \(index + 1) of \(items.count) · \(item.title) · \(TrackTime.text(item.duration))"
            do {
                var song = try await fetchAudio(item, into: staging, position: index + 1)
                if let address = item.artworkURL.flatMap(URL.init(string:)), address.scheme == "https", let (data, _) = try? await artwork.data(from: address), data.count < 10_000_000 { song.artwork = data }
                songs.append(song)
            } catch is CancellationError { failures.append("\(item.title): Cancelled"); break }
            catch { failures.append("\(item.title): \(error.localizedDescription)") }
            completed = index + 1; itemFraction = 1; refreshFraction()
        }
        detail = ""
        return (songs, failures)
    }

    private func fetchAudio(_ item: ScoutTrack, into staging: URL, position: Int) async throws -> DownloadedSong {
        var lastError: Error = ScoutError.message("No downloadable audio link.")
        var seen = Set<String>()
        let addresses = ([item.audioURL] + (item.audioMirrors ?? [])).filter { seen.insert($0).inserted }
        for (index, address) in addresses.enumerated() {
            do {
                try Task.checkCancellation()
                detail = "\(index == 0 ? "Downloading" : "Trying mirror for") \(item.title) · \(TrackTime.text(item.duration))"
                guard let url = URL(string: address), url.scheme == "https" else { throw ScoutError.message("Audio URL must use HTTPS.") }
                let audioURL = try await TrackerAudio.resolve(url, session: artwork)
                try Task.checkCancellation()
                let (temp, http) = try await downloadFile(from: audioURL)
                defer { try? FileManager.default.removeItem(at: temp) }
                guard (200..<300).contains(http.statusCode) else { throw ScoutError.message("Download unavailable") }
                if let mime = http.mimeType, mime.hasPrefix("text/") || ["application/json", "application/pdf"].contains(mime) { throw ScoutError.message("This source returned a document instead of audio.") }
                let size = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1_000_000_000 else { throw ScoutError.message("File exceeds the 1 GB import limit.") }
                return try await DownloadedAudio.prepare(temp, track: item, into: staging) { [weak self] duration in
                    self?.detail = "Converting \(position) of \(self?.total ?? 0) · \(item.title) · \(TrackTime.text(duration))"
                }
            } catch is CancellationError { throw CancellationError() }
            catch { if Task.isCancelled { throw CancellationError() }; lastError = error }
        }
        throw lastError
    }

    private func refreshFraction() {
        guard total > 0 else { fraction = 0; return }
        fraction = min(1, (Double(min(currentIndex, total)) + itemFraction) / Double(total))
    }

    /// One file over the background session, bridged to async. Cancelling the surrounding task
    /// cancels the transfer.
    private func downloadFile(from url: URL) async throws -> (URL, HTTPURLResponse) {
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.register(task, continuation: continuation)
                task.resume()
            }
        } onCancel: { task.cancel() }
    }
}

/// Delegate for the background session: forwards byte progress and moves each finished file out of
/// the temporary location (it is deleted the moment the callback returns) before resuming its
/// waiter. Lives off the main actor — callbacks arrive on the session's own queue — so its state is
/// guarded by a lock.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    private struct Record { let continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>; var moved: URL?; var response: HTTPURLResponse? }
    private let lock = NSLock()
    private var records: [Int: Record] = [:]

    func register(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>) {
        lock.lock(); records[task.taskIdentifier] = Record(continuation: continuation, moved: nil, response: nil); lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ScoutDL-" + UUID().uuidString)
        try? FileManager.default.removeItem(at: destination)
        let moved = (try? FileManager.default.moveItem(at: location, to: destination)) != nil ? destination : nil
        lock.lock()
        records[downloadTask.taskIdentifier]?.moved = moved
        records[downloadTask.taskIdentifier]?.response = downloadTask.response as? HTTPURLResponse
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let record = records.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let record else { return }
        if let error { if let moved = record.moved { try? FileManager.default.removeItem(at: moved) }; record.continuation.resume(throwing: error); return }
        guard let moved = record.moved, let response = record.response else { record.continuation.resume(throwing: ScoutError.message("Download unavailable")); return }
        record.continuation.resume(returning: (moved, response))
    }
}
