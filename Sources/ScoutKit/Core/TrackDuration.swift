import Foundation
import AVFoundation

enum TrackTime {
    static func valid(_ seconds: Double?) -> Double? {
        guard let seconds, seconds.isFinite, seconds > 0, seconds < 31_536_000 else { return nil }
        return seconds
    }
    static func parse(_ text: String?) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = Double(text) { return valid(seconds) }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0.isFinite && $0 >= 0 }),
              numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        return valid(numbers.reduce(0) { $0 * 60 + $1 })
    }
    static func text(_ seconds: Double?) -> String {
        guard let seconds = valid(seconds) else { return "Length unavailable" }
        return position(seconds)
    }
    static func position(_ seconds: Double) -> String {
        let s = seconds.isFinite ? Int(min(31_536_000, max(0, seconds)).rounded()) : 0
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Only visible rows request missing lengths. Shared requests are cached and limited to four.
actor TrackDurationLookup {
    static let shared = TrackDurationLookup()
    private var cache: [String: (Date, Double?)] = [:]
    private var tasks: [String: Task<Double?, Never>] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    func duration(for track: ScoutTrack) async -> Double? {
        if let duration = TrackTime.valid(track.duration) { return duration }
        return await duration(address: track.audioURL)
    }
    func duration(address: String) async -> Double? {
        if let cached = cache[address], cached.1 != nil || Date().timeIntervalSince(cached.0) < 60 { return cached.1 }
        if let task = tasks[address] { return await task.value }
        let task = Task { await self.measure(address) }
        tasks[address] = task
        let result = await task.value
        cache[address] = (Date(), result); tasks[address] = nil
        return result
    }
    private func acquire() async {
        if active < 4 { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().resume() }
    }
    private func measure(_ address: String) async -> Double? {
        await acquire()
        defer { release() }
        guard let url = URL(string: address), ["https", "file"].contains(url.scheme) else { return nil }
        do {
            let audio = try await TrackerAudio.resolve(url, session: session)
            let asset = AVURLAsset(url: audio)
            return await withTaskGroup(of: Double?.self) { group in
                group.addTask { TrackTime.valid(try? await asset.load(.duration).seconds) }
                group.addTask { try? await Task.sleep(for: .seconds(20)); return nil }
                let result = await group.next() ?? nil
                asset.cancelLoading(); group.cancelAll()
                return result
            }
        } catch { return nil }
    }
}
