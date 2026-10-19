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
                let observer = PreviewDownloadProgress { fraction in Task { @MainActor in progress(fraction, "Downloading preview") } }
                let transfer = URLSession(configuration: session.configuration, delegate: observer, delegateQueue: nil)
                defer { transfer.finishTasksAndInvalidate() }
                let (temporary, response) = try await observer.download(audio, session: transfer)
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

private final class PreviewDownloadProgress: NSObject, URLSessionDownloadDelegate {
    let update: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
    private var file: URL?
    init(update: @escaping @Sendable (Double?) -> Void) { self.update = update }
    func download(_ url: URL, session: URLSession) async throws -> (URL, HTTPURLResponse) {
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task.resume()
            }
        } onCancel: { task.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("Scout-preview-transfer-" + UUID().uuidString)
        if (try? FileManager.default.moveItem(at: location, to: target)) != nil { file = target }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { continuation = nil }
        if let error {
            if let file { try? FileManager.default.removeItem(at: file) }
            continuation?.resume(throwing: error)
        } else if let file, let http = task.response as? HTTPURLResponse {
            continuation?.resume(returning: (file, http))
        } else { continuation?.resume(throwing: ScoutError.message("Preview download failed.")) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        update(totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
    }
}
