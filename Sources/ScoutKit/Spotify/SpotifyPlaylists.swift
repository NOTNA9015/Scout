import Foundation
import ObjectiveC
import AVFoundation
import UIKit

/// Spotify's internal services, as Scout uses them. The real one goes through Spotify's own
/// transport (SpotifyTransport.m); tests use a fake.
public protocol SpotifyServices: Sendable {
    var ready: Bool { get async }
    func request(_ service: String, _ method: String, _ data: Data) async throws -> ProtoMessage
}

public struct LiveSpotifyServices: SpotifyServices {
    public init() {}
    /// SpotifyTransport.m's class methods, called through the runtime (the class declares no Swift
    /// protocol, so it can't be cast to one).
    private typealias IsReady = @convention(c) (AnyClass, Selector) -> Bool
    private typealias Completion = @convention(block) (NSData?, NSString?) -> Void
    /// The completion is kept until Spotify answers, so it must be @escaping: a non-escaping block
    /// that is kept makes Swift stop the app as soon as the call returns.
    private typealias Request = @convention(c) (AnyClass, Selector, NSString, NSString, NSData, @escaping Completion) -> Void
    private static func method<T>(_ name: String, as type: T.Type) -> (AnyClass, Selector, T)? {
        guard let cls = NSClassFromString("SCSpotifyTransport") else { return nil }
        let selector = NSSelectorFromString(name)
        guard let method = class_getClassMethod(cls, selector) else { return nil }
        return (cls, selector, unsafeBitCast(method_getImplementation(method), to: type))
    }
    /// A step marker in "Scout playlist log.txt" (inside Spotify only).
    static func log(_ line: String) {
        typealias Log = @convention(c) (AnyClass, Selector, NSString) -> Void
        guard Bundle.main.object(forInfoDictionaryKey: "ScoutVersion") != nil, let (cls, selector, call) = method("log:", as: Log.self) else { return }
        call(cls, selector, line as NSString)
    }
    public var ready: Bool {
        get async { await MainActor.run { Self.method("isReady", as: IsReady.self).map { $0.2($0.0, $0.1) } ?? false } }
    }
    public func request(_ service: String, _ method: String, _ data: Data) async throws -> ProtoMessage {
        guard let (cls, selector, call) = Self.method("request:method:data:completion:", as: Request.self) else {
            throw ScoutError.message("Scout isn't running inside Spotify.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                call(cls, selector, service as NSString, method as NSString, data as NSData) { response, error in
                    Self.log("scout got \(method): " + (error.map { "error \($0)" } ?? response.map { $0.prefix(24).map { String(format: "%02x", $0) }.joined() } ?? "nothing"))
                    if let error { continuation.resume(throwing: ScoutError.message(error as String)) }
                    else if let response { do { continuation.resume(returning: try ProtoMessage(response as Data)) } catch { continuation.resume(throwing: error) } }
                    else { continuation.resume(throwing: ScoutError.message("Spotify returned an empty answer.")) }
                }
            }
        }
    }
}

/// Message shapes for Spotify 9.1.90, from the descriptors embedded in the app.
enum SpotifyMessages {
    static let localFiles = "spotify.local_files_esperanto.proto.LocalFiles"
    static let playlist = "spotify.playlist_esperanto.proto."
    static func path(uri: String) -> Data { var m = ProtoMessage(); m.set(1, string: uri); return m.encoded }
    static func uri(artist: String, album: String, title: String, seconds: Int) -> Data {
        var m = ProtoMessage(); m.set(1, string: artist); m.set(2, string: album); m.set(3, string: title); m.set(4, uint: UInt64(max(0, seconds))); return m.encoded
    }
    static func create(name: String, description: String) -> Data {
        var op = ProtoMessage(), attrs = ProtoMessage(), request = ProtoMessage()
        op.set(1, string: "create"); op.set(4, string: name); op.set(5, uint: 1); op.set(12, uint: 1)
        attrs.set(1, uint: 0); attrs.set(4, string: description); attrs.set(8, uint: 1)
        op.set(6, data: attrs.encoded); request.set(2, data: op.encoded)
        return request.encoded
    }
    static func add(playlist uri: String, tracks: [String]) -> Data {
        var op = ProtoMessage(), request = ProtoMessage(); op.set(1, string: "add")
        for track in tracks { op.append(7, data: Data(track.utf8)) }
        request.set(1, string: uri); request.set(2, data: op.encoded)
        return request.encoded
    }
    static func read(playlist uri: String) -> Data {
        var get = ProtoMessage(), query = ProtoMessage(), range = ProtoMessage()
        get.set(1, string: uri); range.set(1, uint: 0); range.set(2, uint: 100_000); query.set(4, data: range.encoded); query.set(8, uint: 1)
        get.set(2, data: query.encoded)
        var policy = ProtoMessage(), list = ProtoMessage(), item = ProtoMessage()
        for field in [2, 3, 4, 5, 7, 9, 19] { list.set(field, uint: 1) }
        item.set(1, uint: 1); item.set(9, uint: 1)
        policy.set(1, data: list.encoded); policy.set(4, data: item.encoded); get.set(3, data: policy.encoded)
        var single = ProtoMessage(), request = ProtoMessage(); single.set(1, string: "scout"); single.set(2, data: get.encoded); request.append(1, data: single.encoded)
        return request.encoded
    }
    /// Track URIs of a playlist read, in order; nil while Spotify is still loading it.
    static func tracks(in reply: ProtoMessage) throws -> [String]? {
        guard let get = reply.values(2).compactMap({ try? ProtoMessage($0.bytes) }).first(where: { $0.string(1) == "scout" })?.message(3),
              [0, 200].contains(get.message(1)?.uint(1) ?? 500), let data = get.message(2) else { throw ScoutError.message("Spotify returned no playlist contents.") }
        if data.uint(6) == 1 { return nil }
        return try data.values(1).map { field in
            let row = try ProtoMessage(field.bytes)
            guard let uri = row.string(18) ?? row.message(4)?.string(3) else { throw ScoutError.message("Spotify returned an unreadable playlist row.") }
            return uri
        }
    }
}

/// Turns a saved album into a normal Spotify playlist of its local files, in album order.
public struct SpotifyPlaylistPublisher: PlaylistPublishing {
    let services: SpotifyServices
    let musicFolder: URL
    /// How long to wait for Spotify to index freshly saved songs before reporting back.
    let indexWait: [Duration]
    public init(services: SpotifyServices = LiveSpotifyServices(), musicFolder: URL,
                indexWait: [Duration] = [.zero, .seconds(1), .seconds(2), .seconds(3), .seconds(5), .seconds(8), .seconds(13), .seconds(20)]) {
        self.services = services; self.musicFolder = musicFolder; self.indexWait = indexWait
    }

    static let unconfirmed = "Spotify may already have made this playlist. Check Your Library; if it isn't there, tap Compile pending playlists again to make it."
    /// Always returns the plan with its progress recorded (a created playlist's URI, an unconfirmed
    /// create), so a failure part-way never leads to a second playlist.
    public func publish(_ plan: PlaylistPlan, songs: [SavedSong]) async throws -> PlaylistPlan {
        var plan = plan
        do { try await run(&plan, songs: songs) }
        catch is CancellationError { throw CancellationError() }
        catch { plan.status = .failed; plan.lastError = error.localizedDescription }
        return plan
    }
    func run(_ plan: inout PlaylistPlan, songs: [SavedSong]) async throws {
        LiveSpotifyServices.log("compile \(plan.name): \(songs.count) songs, playlist \(plan.playlistURI ?? "not made yet")")
        for _ in 0..<10 where !(await services.ready) { try await Task.sleep(for: .seconds(1)) }
        guard await services.ready else { throw ScoutError.message("Spotify's services aren't ready yet. Play any song for a moment, then tap Compile pending playlists again.") }

        // 1. Scout never changes Spotify's local-file sources: switching one on made Spotify crash
        //    right after it answered. The user's own Settings → Local Files decides what is scanned.

        // 2. Each song's exact spotify:local: URI, confirmed by Spotify pointing back at our file.
        var uris: [UUID: String] = [:]
        for (attempt, wait) in indexWait.enumerated() {
            try await Task.sleep(for: wait)
            for song in songs where uris[song.id] == nil { uris[song.id] = try await resolve(song) }
            if uris.count == songs.count { break }
        }
        let missing = songs.filter { uris[$0.id] == nil }
        guard missing.isEmpty else {
            throw ScoutError.message("Spotify hasn't indexed \(missing.count) of \(songs.count) songs yet. Make sure Local Files is on in Spotify's settings, wait a moment, then tap Compile pending playlists again.")
        }
        let ordered = plan.songIDs.compactMap { id in uris[id] }
        LiveSpotifyServices.log("found all \(ordered.count) songs in Spotify")

        // 3. Create it once. A create that was sent but never confirmed is not repeated blindly.
        if plan.playlistURI == nil {
            if plan.creationStartedAt != nil {
                throw ScoutError.message(Self.unconfirmed)
            }
            plan.creationStartedAt = Date()
            let reply: ProtoMessage
            do {
                reply = try await request("RootlistModificationService", "Modify",
                                          SpotifyMessages.create(name: plan.name, description: Suggestions.joinArtists(plan.artists)))
            } catch is CancellationError { throw CancellationError() }
            catch { throw ScoutError.message(Self.unconfirmed) }   // sent, but we can't know whether Spotify made it
            guard reply.message(2)?.uint(1) == 1, let uri = reply.message(2)?.string(2), uri.hasPrefix("spotify:playlist:") else {
                plan.creationStartedAt = nil
                throw ScoutError.message("Spotify couldn't create the playlist.")
            }
            plan.playlistURI = uri
        }
        guard let uri = plan.playlistURI else { return }

        // 4. Add what is not there yet, then read back the exact order.
        let current = try await contents(uri)
        let toAdd = ordered.filter { !current.contains($0) }
        if !toAdd.isEmpty { _ = try await request("PlaylistService", "Modify", SpotifyMessages.add(playlist: uri, tracks: toAdd)) }
        var confirmed = false
        for attempt in 0..<5 {
            if try await contents(uri).filter({ ordered.contains($0) }) == ordered { confirmed = true; break }
            try await Task.sleep(for: .milliseconds(500 * (attempt + 1)))
        }
        guard confirmed else { throw ScoutError.message("Spotify hasn't confirmed all songs in the playlist yet. Tap Compile pending playlists again in a moment.") }
        plan.status = .published; plan.lastError = nil
        LiveSpotifyServices.log("done \(plan.name)")
    }

    /// The URI spoti.pw would build (artist:album:title:seconds), checked against Spotify's own
    /// answer for which file it plays; then Spotify's lookup as a fallback.
    func resolve(_ song: SavedSong) async throws -> String? {
        LiveSpotifyServices.log("looking up \(song.filename)")
        let file = musicFolder.appendingPathComponent(song.filename)
        let artist = Suggestions.joinArtists(song.artists)
        let length = (try? await AVURLAsset(url: file).load(.duration).seconds) ?? 0
        guard length.isFinite, length > 0 else { return nil }
        let whole = Int(length.rounded(.down))
        let target = file.standardizedFileURL.resolvingSymlinksInPath().path
        func matches(_ uri: String) async -> Bool {
            guard let reply = try? await services.request(SpotifyMessages.localFiles, "GetLocalFilePath", SpotifyMessages.path(uri: uri)),
                  let path = reply.string(1), !path.isEmpty else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == target
        }
        for seconds in [whole, whole + 1, whole - 1] where seconds > 0 {
            let uri = SpotiPWLyrics.localURI(artist: artist, album: song.album, title: song.title, seconds: seconds)
            if await matches(uri) { return uri }
        }
        for seconds in [whole, Int(length.rounded()), whole + 1] {
            guard let reply = try? await services.request(SpotifyMessages.localFiles, "GetLocalFileUri", SpotifyMessages.uri(artist: artist, album: song.album, title: song.title, seconds: seconds)),
                  let uri = reply.string(1), uri.hasPrefix("spotify:local:") else { continue }
            if await matches(uri) { return uri }
        }
        return nil
    }

    private func request(_ area: String, _ method: String, _ data: Data) async throws -> ProtoMessage {
        let reply = try await services.request(SpotifyMessages.playlist + area, method, data)
        guard let status = reply.message(1), [0, 200, 201, 204].contains(status.uint(1) ?? 0) else {
            throw ScoutError.message(reply.message(1)?.string(2) ?? "Spotify refused the playlist change.")
        }
        return reply
    }
    private func contents(_ uri: String) async throws -> [String] {
        for attempt in 0..<5 {
            if let tracks = try SpotifyMessages.tracks(in: try await request("PlaylistDataService", "MultiGet", SpotifyMessages.read(playlist: uri))) { return tracks }
            if attempt < 4 { try await Task.sleep(for: .milliseconds(500)) }
        }
        throw ScoutError.message("Spotify is still loading the playlist. Tap Compile pending playlists again in a moment.")
    }
}

/// Opens a playlist in Spotify through its own URL scheme.
@MainActor public enum SpotifyLinks {
    public static func open(_ uri: String) { if let url = URL(string: uri) { UIApplication.shared.open(url) } }
}
