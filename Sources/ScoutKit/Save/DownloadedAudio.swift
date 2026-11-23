import Foundation

enum DownloadedAudio {
    /// Foreground previews use the same format checks and conversion as imports.
    static func fetchPreview(_ track: ScoutTrack, session: URLSession, into staging: URL,
                             progress: @escaping @MainActor @Sendable (Double?, String) -> Void = { _, _ in }) async throws -> DownloadedSong {
        var lastError: Error = ScoutError.message("No downloadable audio link.")
        var seen = Set<String>()
        for address in ([track.audioURL] + (track.audioMirrors ?? [])).filter({ seen.insert($0).inserted }) {
            do {
                try Task.checkCancellation()
                await progress(0, "Downloading preview")
                guard let url = URL(string: address), url.scheme == "https" else { throw ScoutError.message("Audio URL must use HTTPS.") }
                let audio = try await TrackerAudio.resolve(url, session: session)
                let delegate = DownloadSessionDelegate(), tally = TransferTally()
                delegate.onProgress = { task, written, expected in
                    let fraction = tally.record(task, written: written, expected: expected)
                    Task { @MainActor in progress(fraction, "Downloading preview") }
                }
                // An Archive file comes in ranges side by side (see `SegmentedDownload`).
                let config = session.configuration
                config.httpMaximumConnectionsPerHost = SegmentedDownload.maxParts
                let transfer = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
                defer { transfer.finishTasksAndInvalidate() }
                var download = SegmentedDownload(fetch: { request in try await delegate.download(request, in: transfer) },
                                                 open: SegmentedDownload.streaming(using: session))
                download.sized = { tally.sized($0) }
                let (temporary, response) = try await download.download(audio)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard (200..<300).contains(response.statusCode) else { throw ScoutError.message("Preview unavailable") }
                let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 1_000_000_000 else { throw ScoutError.message("File exceeds the 1 GB preview limit.") }
                await progress(nil, "Checking audio")
                return try await prepare(temporary, track: track, into: staging) { _ in progress(nil, "Converting preview") }
            } catch is CancellationError { throw CancellationError() }
            catch { if Task.isCancelled { throw CancellationError() }; lastError = error }
        }
        throw lastError
    }

    /// Consumes a downloaded temporary file and returns playable audio, before setup is shown.
    static func prepare(_ temporary: URL, track: ScoutTrack, into staging: URL,
                        converting: @MainActor @Sendable (Double) -> Void = { _ in }) async throws -> DownloadedSong {
        let original = try await Task.detached(priority: .userInitiated) {
            let envelope = try AudioCompatibility.envelope(temporary)
            let target: URL
            if envelope.audioOffset == 0 {
                target = staging.appendingPathComponent(UUID().uuidString).appendingPathExtension(envelope.ext)
                try FileManager.default.moveItem(at: temporary, to: target)
            } else { target = try AudioCompatibility.normalizedCopy(temporary, into: staging) }
            do { _ = try AudioCompatibility.inspect(target); return target }
            catch { try? FileManager.default.removeItem(at: target); throw error }
        }.value
        var keepOriginal = false
        defer { if !keepOriginal { try? FileManager.default.removeItem(at: original) } }
        try Task.checkCancellation()
        var song = await DownloadedSong.make(file: original, source: track, artwork: nil)
        let info = try AudioCompatibility.inspect(original)
        if AudioCompatibility.isSpotifyCompatible(info, file: original) {
            keepOriginal = true
            return song
        }
        await converting(info.duration)
        let converted = staging.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        do {
            let tags = TagWriter.Tags(title: song.taggedTitle ?? track.title, artist: song.taggedArtist ?? track.artist,
                                      album: song.taggedAlbum ?? track.album, albumArtist: song.taggedArtist ?? track.artist,
                                      trackNumber: track.trackNumber ?? 0, artwork: song.embeddedArtwork, lyrics: song.taggedLyrics ?? track.lyrics)
            try await TagWriter.write(tags, from: original, to: converted, forceAAC: true)
            try Task.checkCancellation()
            song.file = converted
            song.duration = try AudioCompatibility.inspect(converted).duration
            return song
        } catch { try? FileManager.default.removeItem(at: converted); throw error }
    }
}

/// How far a preview download is, over all of its ranges. Fed from the session's queue.
final class TransferTally: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [Int: (written: Int64, expected: Int64)] = [:]
    private var size: Int64?

    /// The whole file's size when it comes in ranges; nil when it is fetched in one request.
    func sized(_ size: Int64?) { lock.withLock { self.size = size; bytes = [:] } }
    /// A transfer's bytes so far; returns the fraction done, nil while the size is unknown.
    func record(_ task: Int, written: Int64, expected: Int64) -> Double? {
        lock.withLock {
            bytes[task] = (written, expected)
            let got = bytes.values.reduce(0) { $0 + $1.written }
            let total = size ?? (bytes.values.contains { $0.expected <= 0 } ? 0 : bytes.values.reduce(0) { $0 + $1.expected })
            return total > 0 ? min(1, Double(got) / Double(total)) : nil
        }
    }
}
