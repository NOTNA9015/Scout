import Foundation

/// GET with patience: lyrics and catalog services often drop the first request (a cold
/// connection, a short rate limit). Transient failures are retried with growing pauses.
enum Net {
    static let pauses: [Duration] = [.milliseconds(600), .milliseconds(1500), .seconds(3), .seconds(5)]

    /// nil only when every attempt failed; any definite answer (200, 404, …) is returned at once.
    static func get(_ url: URL, session: URLSession) async -> (Data, HTTPURLResponse)? {
        for attempt in 0...pauses.count {
            if Task.isCancelled { return nil }
            var retryAfter: Duration?
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else { continue }
                if http.statusCode == 429 || http.statusCode >= 500 {
                    if let header = http.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header) { retryAfter = .milliseconds(Int(min(seconds, 10) * 1000)) }
                } else { return (data, http) }
            } catch is CancellationError { return nil }
            catch let error as URLError where error.code == .cancelled { return nil }
            catch {}
            guard attempt < pauses.count else { break }
            try? await Task.sleep(for: retryAfter ?? pauses[attempt])
        }
        return nil
    }
}
