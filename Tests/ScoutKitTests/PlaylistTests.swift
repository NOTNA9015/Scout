import XCTest
import AVFoundation
@testable import ScoutKit

/// Answers like Spotify's local-files and playlist services, from what it has been told.
actor FakeSpotify: SpotifyServices {
    var paths: [String: String] = [:]          // spotify:local: URI → file path Spotify plays
    var playlists: [String: [String]] = [:]
    var creates = 0
    var failCreate = false
    var calls: [String] = []
    nonisolated var ready: Bool { get async { true } }
    func index(_ uri: String, _ path: String) { paths[uri] = path }
    func setFailCreate(_ value: Bool) { failCreate = value }
    func request(_ service: String, _ method: String, _ data: Data) async throws -> ProtoMessage {
        calls.append(method)
        let input = try ProtoMessage(data)
        var reply = ProtoMessage(), status = ProtoMessage(); status.set(1, uint: 200)
        switch method {
        case "GetLocalFilePath":
            if let path = paths[input.string(1) ?? ""] { reply.set(1, string: path) }
            return reply
        case "GetLocalFileUri": return reply
        case "Modify" where service.hasSuffix("RootlistModificationService") && input.message(2)?.string(1) == "remove":
            for uri in input.message(2)?.values(7) ?? [] { playlists[String(decoding: uri.bytes, as: UTF8.self)] = nil }
            reply.set(1, data: status.encoded); return reply
        case "Modify" where service.hasSuffix("RootlistModificationService"):
            creates += 1
            if failCreate { throw ScoutError.message("Spotify didn't answer in time.") }
            let uri = "spotify:playlist:fake\(creates)"; playlists[uri] = []
            var result = ProtoMessage(); result.set(1, uint: 1); result.set(2, string: uri)
            reply.set(1, data: status.encoded); reply.set(2, data: result.encoded); return reply
        case "Modify":
            let uri = input.string(1) ?? ""
            let op = input.message(2)
            let tracks = op?.values(7).map { String(decoding: $0.bytes, as: UTF8.self) } ?? []
            if op?.string(1) == "remove" { playlists[uri]?.removeAll { tracks.contains($0) } }
            else { playlists[uri, default: []] += tracks }
            reply.set(1, data: status.encoded); return reply
        case "MultiGet":
            let single = try ProtoMessage(input.values(1)[0].bytes)
            let uri = single.message(2)?.string(1) ?? ""
            var contents = ProtoMessage()
            for track in playlists[uri] ?? [] { var row = ProtoMessage(); row.set(18, string: track); contents.append(1, data: row.encoded) }
            var get = ProtoMessage(); get.set(1, data: status.encoded); get.set(2, data: contents.encoded)
            var answer = ProtoMessage(); answer.set(1, string: "scout"); answer.set(3, data: get.encoded)
            reply.set(1, data: status.encoded); reply.append(2, data: answer.encoded); return reply
        default: throw ScoutError.message("unexpected \(method)")
        }
    }
}

@MainActor final class PlaylistTests: XCTestCase {
    var work: URL!
    var library: ScoutLibrary!
    override func setUp() async throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        library = ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support"))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work) }

    func tone(_ seconds: Double) throws -> URL {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let url = work.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(8000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!; buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }
    func saveAlbum(_ titles: [String]) async throws -> [SavedSong] {
        var saved: [SavedSong] = []
        for (index, title) in titles.enumerated() {
            var draft = SongDraft(song: await DownloadedSong.make(file: try tone(2.4 + Double(index)), source: nil, artwork: nil))
            draft.title = title; draft.artists = ["Ines Vale", "Juno Reyes"]; draft.trackNumber = index + 1
            saved.append(try await library.save(draft, lyrics: nil, lyricsSource: nil, album: "The Quiet Hours", albumArtist: "Ines Vale"))
        }
        return saved
    }
    /// What Spotify indexes for a saved file: spoti.pw's URI shape and the file's path.
    func index(_ songs: [SavedSong], in spotify: FakeSpotify) async throws {
        for song in songs {
            let file = library.fileURL(song)
            let seconds = Int(try await AVURLAsset(url: file).load(.duration).seconds.rounded(.down))
            await spotify.index(SpotiPWLyrics.localURI(artist: "Ines Vale, Juno Reyes", album: "The Quiet Hours", title: song.title, seconds: seconds), file.path)
        }
    }
    func plan(_ songs: [SavedSong]) -> PlaylistPlan {
        PlaylistPlan(id: UUID(), name: "The Quiet Hours", artists: ["Ines Vale"], coverFilename: nil, songIDs: songs.map(\.id), status: .pending, playlistURI: nil, lastError: nil, createdAt: Date())
    }

    func testAlbumBecomesAPlaylistInOrderAndIsNotMadeTwice() async throws {
        let songs = try await saveAlbum(["Night Bus", "Paper Boats"])
        let spotify = FakeSpotify(); try await index(songs, in: spotify)
        let publisher = SpotifyPlaylistPublisher(services: spotify, musicFolder: library.musicFolder, indexWait: [.zero])
        let done = try await publisher.publish(plan(songs), songs: songs)
        XCTAssertEqual(done.status, .published, done.lastError ?? "")
        let uri = try XCTUnwrap(done.playlistURI)
        let tracks = await spotify.playlists[uri]
        XCTAssertEqual(tracks?.count, 2)
        XCTAssertTrue(tracks?[0].contains("Night+Bus") ?? false); XCTAssertTrue(tracks?[1].contains("Paper+Boats") ?? false)
        let again = try await publisher.publish(done, songs: songs)
        let creates = await spotify.creates
        XCTAssertEqual(creates, 1); XCTAssertEqual(again.playlistURI, uri)
        let afterAgain = await spotify.playlists[uri]
        XCTAssertEqual(afterAgain?.count, 2, "a second run adds nothing already there")
    }

    func testSongsSpotifyHasNotIndexedNeverMakeAnEmptyPlaylist() async throws {
        let songs = try await saveAlbum(["Night Bus"])
        let spotify = FakeSpotify()
        let result = try await SpotifyPlaylistPublisher(services: spotify, musicFolder: library.musicFolder, indexWait: [.zero]).publish(plan(songs), songs: songs)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.lastError?.contains("hasn't indexed 1 of 1") ?? false, result.lastError ?? "")
        XCTAssertNil(result.creationStartedAt)
        let creates = await spotify.creates
        XCTAssertEqual(creates, 0)
    }

    func testAnUnconfirmedCreateIsNotRepeatedUntilTheUserRetries() async throws {
        let songs = try await saveAlbum(["Night Bus"])
        let spotify = FakeSpotify(); try await index(songs, in: spotify)
        await spotify.setFailCreate(true)
        let publisher = SpotifyPlaylistPublisher(services: spotify, musicFolder: library.musicFolder, indexWait: [.zero])
        let first = try await publisher.publish(plan(songs), songs: songs)
        XCTAssertEqual(first.status, .failed); XCTAssertNotNil(first.creationStartedAt); XCTAssertNil(first.playlistURI)
        await spotify.setFailCreate(false)
        let second = try await publisher.publish(first, songs: songs)
        let creates = await spotify.creates
        XCTAssertEqual(creates, 1, "no second create on its own")
        XCTAssertTrue(second.lastError?.contains("may already have made") ?? false)
        // The user checked and retries: now it may create.
        var retry = second; retry.creationStartedAt = nil
        let third = try await publisher.publish(retry, songs: songs)
        XCTAssertEqual(third.status, .published)
    }

    func testCompileMakesWaitingAlbumsAndRepeatsAnUnconfirmedCreateOnlyOnTheSecondTap() async throws {
        let songs = try await saveAlbum(["Night Bus"])
        let spotify = FakeSpotify(); try await index(songs, in: spotify)
        library.publisher = SpotifyPlaylistPublisher(services: spotify, musicFolder: library.musicFolder, indexWait: [.zero])
        try await library.plan(album: "The Quiet Hours", artists: ["Ines Vale"], cover: nil, songs: songs)
        let untouched = await spotify.creates
        XCTAssertEqual(untouched, 0, "importing only records the album")
        XCTAssertEqual(library.waiting.count, 1)

        await spotify.setFailCreate(true)
        let first = await library.compileWaiting()
        XCTAssertEqual(first.failed.first?.lastError, SpotifyPlaylistPublisher.unconfirmed)
        await spotify.setFailCreate(false)
        let second = await library.compileWaiting()
        XCTAssertEqual(second.made.count, 1, second.failed.first?.lastError ?? "")
        XCTAssertTrue(library.waiting.isEmpty)
        let nothing = await library.compileWaiting()
        XCTAssertTrue(nothing.made.isEmpty && nothing.failed.isEmpty)
    }

    /// The real bridge to SpotifyTransport.m is reached (outside Spotify it has no transport).
    func testLiveServicesReachTheTransportBridge() async {
        let ready = await LiveSpotifyServices().ready
        XCTAssertFalse(ready)
        do { _ = try await LiveSpotifyServices().request("s", "m", Data()); XCTFail("no transport in the test host") }
        catch { XCTAssertTrue(error.localizedDescription.contains("aren't ready yet"), error.localizedDescription) }
    }

    func testDeletedSongsLeaveWaitingAlbumsAndAnEmptyAlbumIsDropped() async throws {
        let songs = try await saveAlbum(["Night Bus", "Paper Boats"])
        let other = try await saveAlbum(["Salt and Cedar"])
        try await library.plan(album: "The Quiet Hours", artists: ["Ines Vale"], cover: Data([0xFF, 0xD8, 0xFF]), songs: songs)
        try await library.plan(album: "Salt", artists: ["Ines Vale"], cover: nil, songs: other)
        try FileManager.default.removeItem(at: library.fileURL(songs[0]))   // deleted in Files
        try FileManager.default.removeItem(at: library.fileURL(other[0]))
        XCTAssertEqual(library.forgetMissingFiles(), 2)
        XCTAssertEqual(library.waiting.map(\.name), ["The Quiet Hours"])
        XCTAssertEqual(library.waiting.first?.songIDs, [songs[1].id])
        XCTAssertEqual(library.songs.map(\.id), [songs[1].id])
        let reloaded = ScoutLibrary(documents: work.appendingPathComponent("Docs"), support: work.appendingPathComponent("Support"))
        XCTAssertEqual(reloaded.playlists.count, 1, "the change is saved")
        XCTAssertEqual(library.forgetMissingFiles(), 0)
    }

    /// Answers on another thread a moment after the call has returned, as Spotify's transport does.
    @objc final class LaterTransport: NSObject {
        @objc(callSingle:method:payload:onResponse:)
        func callSingle(_ service: String, method: String, payload: Data, onResponse: @escaping (Data) -> Void) -> AnyObject {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { var reply = ProtoMessage(); reply.set(1, string: "/x/" + method); onResponse(reply.encoded) }
            return NSObject()
        }
    }
    func testLiveServicesKeepTheCompletionUntilALateAnswer() async throws {
        let bridge: AnyClass = try XCTUnwrap(NSClassFromString("SCSpotifyTransport"))
        typealias Use = @convention(c) (AnyClass, Selector, AnyObject?) -> Void
        let selector = NSSelectorFromString("useTransport:")
        let use = unsafeBitCast(method_getImplementation(try XCTUnwrap(class_getClassMethod(bridge, selector))), to: Use.self)
        use(bridge, selector, LaterTransport())
        defer { use(bridge, selector, nil) }
        let ready = await LiveSpotifyServices().ready
        XCTAssertTrue(ready)
        let reply = try await LiveSpotifyServices().request(SpotifyMessages.localFiles, "GetLocalFilePath", SpotifyMessages.path(uri: "spotify:local:a:b:c:1"))
        XCTAssertEqual(reply.string(1), "/x/GetLocalFilePath")
    }
}
