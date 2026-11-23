import Foundation

/// Fetches one file from the Internet Archive as several byte ranges at once, then joins them.
///
/// The Archive serves each connection at its own pace, mostly 1–3 MB/s and sometimes much less,
/// and connections add up. Measured on 2026-11-23 (44–63 MB FLACs and 8–15 MB MP3s), one request
/// ran at 0.6–1.6 MB/s on a file the Archive hadn't served lately. Six ranges side by side ran at
/// 3–4 MB/s, except when one slow range held up the whole file. So a file comes in about two
/// ranges per connection, and near the end a range that is taking much longer than the others is
/// asked for again on an idle connection. Whichever copy lands first is kept. Other hosts, and
/// files too small to gain, get one plain request as before.
struct SegmentedDownload {
    /// Connections to one file at most, as many as a browser opens to one host. The download
    /// sessions allow no more than this to a host.
    static let maxParts = 6
    /// Ranges are no smaller than this. Each waits about 0.3 s for its first byte and then moves
    /// 0.5–1 MB/s, so a smaller one spends too much of its time waiting.
    static let minimumRange: Int64 = 1_500_000

    /// Whether `url` is on the Internet Archive, which takes ranges and limits each connection.
    static func splits(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "archive.org" || host.hasSuffix(".archive.org")
    }
    /// The ranges a file of `size` bytes comes in, in order and covering every byte, and how many
    /// connections fetch them. The first is `minimumRange` long, because it is asked for before
    /// the size is known; the rest come about two per connection, fewer for a small file.
    static func plan(size: Int64) -> (ranges: [ClosedRange<Int64>], connections: Int) {
        guard size > 0 else { return ([], 0) }
        let first = 0...(min(size, minimumRange) - 1)
        guard size > minimumRange else { return ([first], 1) }
        let pieces = Int64(maxParts * 2 - 1)
        let length = max(minimumRange, (size - minimumRange + pieces - 1) / pieces)
        let rest = stride(from: minimumRange, to: size, by: Int(length)).map { $0...(min(size, $0 + length) - 1) }
        return ([first] + rest, min(maxParts, 1 + rest.count))
    }
    /// The whole file's size from a ranged answer's "Content-Range: bytes 0-0/44564991".
    static func total(contentRange: String?) -> Int64? {
        guard let contentRange, let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }
    /// Where a ranged answer starts: "bytes 2000000-3999999/44564991" → 2000000.
    static func start(contentRange: String?) -> Int64? {
        guard let contentRange, let bytes = contentRange.split(separator: " ").last, let dash = bytes.firstIndex(of: "-") else { return nil }
        return Int64(bytes[..<dash])
    }

    /// A request whose answer's headers are in while its body is still coming.
    struct Opened {
        let response: HTTPURLResponse
        /// Saves the rest of the body to a file.
        let body: @Sendable () async throws -> URL
        let cancel: @Sendable () -> Void
    }

    /// Runs one request to a file on disk (the background session for imports).
    let fetch: @Sendable (URLRequest) async throws -> (URL, HTTPURLResponse)
    /// Starts a request in the foreground and returns once its headers are in. The first range goes
    /// this way: its answer says how big the file is and which server has it, and the other ranges
    /// start while its bytes are still coming in.
    let open: @Sendable (URLRequest) async throws -> Opened
    /// Told the file's size when it is fetched in ranges, and nil when it is fetched whole after all.
    var sized: @Sendable (Int64?) -> Void = { _ in }
    /// A range is asked for again only once it has run this long, and half again as long as a
    /// typical range of this file took.
    var patience: Duration = .seconds(1)

    /// `open` over a foreground session; `progress` hears the bytes saved so far.
    static func streaming(using session: URLSession, progress: @escaping @Sendable (Int64) -> Void = { _ in }) -> @Sendable (URLRequest) async throws -> Opened {
        { request in
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { bytes.task.cancel(); throw ScoutError.message("Download unavailable") }
            return Opened(response: http, body: {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("ScoutDL-" + UUID().uuidString)
                guard FileManager.default.createFile(atPath: file.path, contents: nil) else { bytes.task.cancel(); throw ScoutError.message("Could not save the download.") }
                do {
                    let output = try FileHandle(forWritingTo: file)
                    defer { try? output.close() }
                    var buffer = Data(capacity: 1 << 16), saved: Int64 = 0
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count == 1 << 16 {
                            try output.write(contentsOf: buffer); saved += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                            progress(saved)
                        }
                    }
                    try output.write(contentsOf: buffer)
                    progress(saved + Int64(buffer.count))
                    return file
                } catch {
                    bytes.task.cancel(); try? FileManager.default.removeItem(at: file)
                    throw Task.isCancelled ? CancellationError() : error
                }
            }, cancel: { bytes.task.cancel() })
        }
    }

    /// The file at `url`: an Archive file in ranges side by side, anything else in one request, as
    /// is a file whose server doesn't answer the first range as asked or whose ranges fail.
    func download(_ url: URL) async throws -> (URL, HTTPURLResponse) {
        guard Self.splits(url) else { return try await fetch(URLRequest(url: url)) }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(Self.minimumRange - 1)", forHTTPHeaderField: "Range")
        guard let opened = try? await open(request) else {
            try Task.checkCancellation()
            return try await fetch(URLRequest(url: url))
        }
        let http = opened.response
        guard http.statusCode == 206, Self.start(contentRange: http.value(forHTTPHeaderField: "Content-Range")) == 0,
              let size = Self.total(contentRange: http.value(forHTTPHeaderField: "Content-Range")) else {
            opened.cancel()
            try Task.checkCancellation()
            return try await fetch(URLRequest(url: url))
        }
        // Ranges go straight to the server the Archive sent the first one to, skipping the redirect.
        let served = http.url.flatMap { $0.scheme == "https" && Self.splits($0) ? $0 : nil } ?? url
        sized(size)
        do { return try await parts(of: served, size: size, first: opened) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            sized(nil)
            return try await fetch(URLRequest(url: url))
        }
    }

    private enum Event { case finished(Int, Result<(URL, HTTPURLResponse), Error>), tick }

    /// The file in ranges, joined; the first is already on its way as `first`. Every range is asked
    /// for at once: the session works through them `connections` at a time, and keeps doing so
    /// while the app is suspended.
    private func parts(of url: URL, size: Int64, first opened: Opened) async throws -> (URL, HTTPURLResponse) {
        let (ranges, connections) = Self.plan(size: size)
        let (events, sink) = AsyncStream.makeStream(of: Event.self)
        let attempts = Attempts(), clock = ContinuousClock()
        var files = [URL?](repeating: nil, count: ranges.count), first: HTTPURLResponse?, failure: Error?
        defer { for case let file? in files { try? FileManager.default.removeItem(at: file) } }
        // Requests not finished, in the order asked for; the range each is for; when each began.
        var running: [Int] = [], range: [Int: Int] = [:], since: [Int: ContinuousClock.Instant] = [:]
        var failures = [Int](repeating: 0, count: ranges.count), took: [Duration] = [], next = 0

        func ask(_ piece: Int, opened: Opened? = nil) {
            let attempt = next; next += 1
            running.append(attempt); range[attempt] = piece
            let bytes = ranges[piece]
            attempts.add(attempt, Task {
                let result: Result<(URL, HTTPURLResponse), Error>
                do {
                    if let opened { result = .success(try await finish(opened, bytes)) }
                    else { result = .success(try await part(url, bytes)) }
                } catch { result = .failure(error) }
                if case .terminated = sink.yield(.finished(attempt, result)), case .success(let (file, _)) = result {
                    try? FileManager.default.removeItem(at: file)
                }
            })
        }
        /// The session serves requests in the order asked for, `connections` at a time. Once a
        /// connection is idle, a range running alone for much longer than usual is asked for again.
        func review() {
            let now = clock.now
            for attempt in running.prefix(connections) where since[attempt] == nil { since[attempt] = now }
            guard running.count < connections, !took.isEmpty else { return }
            let limit = max(took.sorted()[took.count / 2] * 1.5, patience)
            let copies = Dictionary(grouping: running) { range[$0] ?? -1 }
            for attempt in running where running.count < connections {
                guard let piece = range[attempt], files[piece] == nil, copies[piece]?.count == 1,
                      let start = since[attempt], now - start > limit else { continue }
                ask(piece)
                since[next - 1] = now
            }
        }

        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if case .terminated = sink.yield(.tick) { return }
            }
        }
        var iterator = events.makeAsyncIterator()
        await withTaskCancellationHandler {
            for piece in ranges.indices { ask(piece, opened: piece == 0 ? opened : nil) }
            review()
            while files.contains(nil), failure == nil, let event = await iterator.next() {
                if case .finished(let attempt, let result) = event, let piece = range.removeValue(forKey: attempt) {
                    running.removeAll { $0 == attempt }
                    let start = since.removeValue(forKey: attempt)
                    attempts.forget(attempt)
                    switch result {
                    case .success(let (file, http)) where files[piece] == nil:
                        files[piece] = file
                        if piece == 0 { first = http }
                        if let start { took.append(clock.now - start) }
                        // The other copy stops; its connection is free for the next range at once.
                        for other in running where range[other] == piece { attempts.cancel(other) }
                        running.removeAll { range[$0] == piece }
                    case .success(let (file, _)):
                        try? FileManager.default.removeItem(at: file)
                    case .failure(let error):
                        // Another copy may still bring it; otherwise it is asked for once more.
                        guard files[piece] == nil, !running.contains(where: { range[$0] == piece }) else { break }
                        failures[piece] += 1
                        if error is CancellationError || failures[piece] >= 2 { failure = error } else { ask(piece) }
                    }
                }
                review()
            }
        } onCancel: { sink.finish(); attempts.cancelAll(); opened.cancel() }
        sink.finish(); attempts.cancelAll(); ticker.cancel()
        while let event = await iterator.next() {
            if case .finished(_, .success(let (file, _))) = event { try? FileManager.default.removeItem(at: file) }
        }
        if let failure { throw failure }
        try Task.checkCancellation()
        guard let first, !files.contains(nil) else { throw ScoutError.message("Download unavailable") }

        let joined = FileManager.default.temporaryDirectory.appendingPathComponent("ScoutDL-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: joined.path, contents: nil) else { throw ScoutError.message("Could not save the download.") }
        do {
            let output = try FileHandle(forWritingTo: joined)
            defer { try? output.close() }
            for case let file? in files {
                let input = try FileHandle(forReadingFrom: file)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty { try output.write(contentsOf: chunk) }
            }
        } catch { try? FileManager.default.removeItem(at: joined); throw error }
        return (joined, first)
    }

    /// The first range's body, checked like any other.
    private func finish(_ opened: Opened, _ range: ClosedRange<Int64>) async throws -> (URL, HTTPURLResponse) {
        let file = try await opened.body()
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        guard size == range.upperBound - range.lowerBound + 1 else {
            try? FileManager.default.removeItem(at: file)
            throw ScoutError.message("The server sent the wrong part of the file.")
        }
        return (file, opened.response)
    }

    /// One range, checked: the server must send exactly the bytes asked for.
    private func part(_ url: URL, _ range: ClosedRange<Int64>) async throws -> (URL, HTTPURLResponse) {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let file: URL, http: HTTPURLResponse
        do { (file, http) = try await fetch(request) }
        catch { throw Task.isCancelled ? CancellationError() : error }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        guard http.statusCode == 206, size == range.upperBound - range.lowerBound + 1,
              Self.start(contentRange: http.value(forHTTPHeaderField: "Content-Range")) == range.lowerBound else {
            try? FileManager.default.removeItem(at: file)
            throw ScoutError.message("The server sent the wrong part of the file.")
        }
        return (file, http)
    }
}

/// The requests of one ranged download, so a copy that lost, or all of them, can be cancelled.
private final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var closed = false

    func add(_ id: Int, _ task: Task<Void, Never>) {
        let keep = lock.withLock { () -> Bool in
            guard !closed else { return false }
            tasks[id] = task
            return true
        }
        if !keep { task.cancel() }
    }
    func forget(_ id: Int) { _ = lock.withLock { tasks.removeValue(forKey: id) } }
    func cancel(_ id: Int) { lock.withLock { tasks.removeValue(forKey: id) }?.cancel() }
    func cancelAll() {
        let all = lock.withLock { () -> [Task<Void, Never>] in
            closed = true
            defer { tasks = [:] }
            return Array(tasks.values)
        }
        all.forEach { $0.cancel() }
    }
}

/// Delegate for a download session (the background one for imports, a foreground one for
/// previews): forwards each transfer's bytes and moves each finished file out of the temporary
/// location (it is deleted the moment the callback returns) before resuming its waiter. Callbacks
/// arrive on the session's own queue, so its state is guarded by a lock.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// A transfer's id, its bytes written so far and the expected total (-1 when the server doesn't say).
    var onProgress: (@Sendable (Int, Int64, Int64) -> Void)?
    private struct Record { let continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>; var moved: URL?; var response: HTTPURLResponse? }
    private let lock = NSLock()
    private var records: [Int: Record] = [:]

    func register(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>) {
        lock.lock(); records[task.taskIdentifier] = Record(continuation: continuation, moved: nil, response: nil); lock.unlock()
    }
    /// One request to a file on disk, bridged to async. `started` gets the transfer's id first;
    /// cancelling the surrounding task cancels the transfer.
    func download(_ request: URLRequest, in session: URLSession, started: (Int) -> Void = { _ in }) async throws -> (URL, HTTPURLResponse) {
        let task = session.downloadTask(with: request)
        started(task.taskIdentifier)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(task, continuation: continuation)
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress?(downloadTask.taskIdentifier, totalBytesWritten, totalBytesExpectedToWrite)
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
