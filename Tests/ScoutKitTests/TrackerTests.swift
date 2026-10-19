import XCTest
@testable import ScoutKit

final class TrackerParsingTests: XCTestCase {
    static let fileID = "6121dce2d0fb1956d05ea408e705d2cf"
    static let index = #"items.push({name: "🎵 Unreleased", pageUrl: "\/unreleased?headers\x3dtrue", gid: "1"});items.push({name: "🎧 Released", pageUrl: "\/released", gid: "2"});items.push({name: "Notes", pageUrl: "\/notes", gid: "3"});"#
    static let sheet = """
    <table><tr><td colspan="9">Join our Discord</td></tr>
    <tr><th>1</th><td>Era</td><td>Name<br>(Tracker website)</td><td>Notes</td><td>Track Length</td><td>File Date</td><td>Leak Date</td><td>Available Length</td><td>Quality</td><td>Link(s)</td><td>Mirror Link</td></tr>
    <tr><td>Blond</td><td>White Ferrari [V2]<br>(feat. James Blake)</td><td>Notes</td><td>3:30</td><td></td><td></td><td>Full</td><td>Lossless</td><td><a href="https://www.google.com/url?q=https://pillows.su/f/\(fileID)&amp;sa=D">Listen</a></td><td><a href="https://imgur.gg/f/mirror">Mirror</a></td></tr>
    <tr><td>Blond</td><td>Unknown song</td><td></td><td></td><td></td><td></td><td>Confirmed</td><td>Not Available</td><td><a href="https://pillows.su/f/00000000000000000000000000000000">Placeholder</a></td></tr>
    <tr><td>Blond</td><td>Video only</td><td></td><td></td><td></td><td></td><td>Snippet</td><td>Recording</td><td><a href="https://youtube.com/watch?v=test">Video</a></td></tr>
    <tr><td>Blond</td><td>Alternate &amp; &#39;Demo&#39;</td><td></td><td></td><td></td><td></td><td>Snippet</td><td>High Quality</td><td><a href="https://imgur.gg/f/abc123">Listen</a></td></tr>
    </table>
    """

    func testTrackerQueriesAndAliases() throws {
        for (query, expected) in [("franck ocean tracker", ArtistTracker.frankOcean), ("FRANK OCEAN TRACKER", .frankOcean), ("ye tracker", .ye), ("kanye west tracker", .ye), ("kendrick tracker", .kendrick), ("Kendrick Lamar tracker", .kendrick)] {
            let search = try XCTUnwrap(TrackerSearch.resolve(query, source: "Internet Archive"))
            XCTAssertEqual(search.tracker, expected)
            XCTAssertTrue(search.terms.isEmpty, query)
        }
        XCTAssertEqual(TrackerSearch.resolve("tracker", artist: "Kendrick", source: "Internet Archive")?.tracker, .kendrick)
        XCTAssertNil(TrackerSearch.resolve("ye", source: "Internet Archive"), "ordinary album searches still use Archive")
        XCTAssertNil(TrackerSearch.resolve("yesterday tracker", source: "Internet Archive"), "short aliases match whole words")
        XCTAssertNil(TrackerSearch.resolve("ye tracker", source: "https://example.com/index.json"), "custom sources stay selected")
        XCTAssertEqual(TrackerSearch.resolve("ye", source: ArtistTracker.ye.rawValue)?.terms, ["ye"], "an album named Ye must filter the list")
        XCTAssertEqual(TrackerSearch.resolve("kendrick tracker", source: ArtistTracker.ye.rawValue)?.tracker, .kendrick)
    }

    func testFiltersTitlesErasAndVersionsWithoutArtistOrTrackerTerms() throws {
        let tracks = TrackerHTML.tracks(in: Self.sheet, tracker: .frankOcean)
        let search = try XCTUnwrap(TrackerSearch.resolve("franck ocean tracker blond lossless", source: "Internet Archive"))
        XCTAssertEqual(search.filter(tracks).map(\.title), ["White Ferrari [V2] (feat. James Blake)"])
        XCTAssertEqual(TrackerSearch.resolve("ferrari v2", source: ArtistTracker.frankOcean.rawValue)?.filter(tracks).count, 1)
        XCTAssertEqual(TrackerSearch.resolve("", source: ArtistTracker.frankOcean.rawValue)?.filter(tracks).count, 2)
        XCTAssertTrue(try XCTUnwrap(TrackerSearch.resolve("nonexistent", source: ArtistTracker.frankOcean.rawValue)).filter(tracks).isEmpty)
    }

    func testDiscoversOnlyMusicTabsAndDecodesPreviewURLs() {
        let sheets = TrackerHTML.sheets(in: Self.index, relativeTo: ArtistTracker.frankOcean.url)
        XCTAssertEqual(sheets.map(\.url.absoluteString), ["https://franktracker.net/unreleased?headers=true", "https://franktracker.net/released"])
        let google = #"items.push({name: "Unreleased", pageUrl: "https:\/\/docs.google.com\/spreadsheets\/d\/test\/preview\/sheet?gid=123"});"#
        XCTAssertEqual(TrackerHTML.sheets(in: google, relativeTo: ArtistTracker.kendrick.url).first?.url.host, "docs.google.com")
    }

    func testPreservesTrackMetadataAndSkipsUnavailableOrUnsupportedRows() {
        let tracks = TrackerHTML.tracks(in: Self.sheet, tracker: .frankOcean)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].artist, "Frank Ocean")
        XCTAssertEqual(tracks[0].album, "Blond")
        XCTAssertEqual(tracks[0].version, "Full · Lossless")
        XCTAssertEqual(tracks[0].duration, 210)
        XCTAssertNil(tracks[1].duration)
        XCTAssertEqual(tracks[0].audioURL, "https://api.pillows.su/api/get/" + Self.fileID)
        XCTAssertEqual(tracks[0].sourceURL, "https://pillows.su/f/" + Self.fileID)
        XCTAssertEqual(tracks[0].audioMirrors, ["https://imgur.gg/f/mirror"])
        XCTAssertEqual(tracks[1].title, "Alternate & 'Demo'")
        XCTAssertEqual(tracks[1].audioURL, "https://imgur.gg/f/abc123")
    }

    func testSupportedLinksAndEmbeddedAudio() {
        XCTAssertNil(TrackerAudio.audioURL(for: "https://pillows.su.evil.com/f/" + Self.fileID))
        XCTAssertNil(TrackerAudio.audioURL(for: "http://example.com/song.mp3"))
        XCTAssertNil(TrackerAudio.audioURL(for: "https://youtube.com/watch?v=demo"))
        XCTAssertEqual(TrackerAudio.audioURL(for: "https://example.com/song.flac")?.pathExtension, "flac")
        let page = #"<audio controls src="https://b.imgur.gg/abc-Song.flac?x=1&amp;y=2"></audio>"#
        XCTAssertEqual(TrackerAudio.embeddedAudio(in: page, relativeTo: ArtistTracker.ye.url)?.absoluteString, "https://b.imgur.gg/abc-Song.flac?x=1&y=2")
        XCTAssertNil(TrackerAudio.embeddedAudio(in: #"<audio src="http://example.com/song.mp3">"#, relativeTo: ArtistTracker.ye.url))
    }

}

private final class TrackerProtocol: URLProtocol {
    static var reply: (URLRequest) -> (Int, String) = { _ in (404, "") }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.reply(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class TrackerServiceTests: XCTestCase {
    private func session(failReleased: Bool = false) -> URLSession {
        TrackerProtocol.reply = { request in
            switch request.url!.path {
            case "/", "/spreadsheets/d/1i4OQglDHiiqMDthqfUFPutGmpZzK7n63LaoWApqhQXI/preview": return (200, TrackerParsingTests.index)
            case "/unreleased": return (200, TrackerParsingTests.sheet)
            case "/released": return failReleased ? (503, "Unavailable") : (200, TrackerParsingTests.sheet)
            case "/f/abc123": return (200, #"<audio src="https://b.imgur.gg/abc123.mp3"></audio>"#)
            case "/metadata/timed-album": return (200, #"{"files":[{"name":"one.mp3","title":"One","length":"3:42.5"},{"name":"two.flac","title":"Two","length":123.75},{"name":"three.mp3","title":"Three"}]}"#)
            default: return (404, "Unknown URL")
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TrackerProtocol.self]
        return URLSession(configuration: config)
    }

    func testServiceRoutesNamedQueriesAndDeduplicatesTabs() async {
        let scout = ScoutService(session: session())
        for (text, tracker) in [("franck ocean tracker", ArtistTracker.frankOcean), ("ye tracker", .ye), ("kendrick tracker", .kendrick)] {
            await scout.search(text)
            XCTAssertEqual(scout.tracker, tracker)
            XCTAssertEqual(scout.sourceName, tracker.rawValue)
            XCTAssertEqual(scout.tracks.count, 2)
            XCTAssertTrue(scout.tracks.allSatisfy { $0.artist == tracker.artist })
            XCTAssertTrue(scout.collections.isEmpty)
            XCTAssertFalse(scout.loading)
            XCTAssertNil(scout.error)
        }
        await scout.search("ferrari", source: ArtistTracker.frankOcean.rawValue)
        XCTAssertEqual(scout.tracks.count, 1)
        await scout.search("no such song", source: ArtistTracker.frankOcean.rawValue)
        XCTAssertTrue(scout.tracks.isEmpty)
        XCTAssertTrue(scout.error?.contains("No audio links match") == true)
    }

    func testTrackerFiltersAsYouTypeWithoutAnotherSearchAndKeepsItsSource() async {
        let scout = ScoutService(session: session())
        await scout.search("ye tracker")
        XCTAssertEqual(scout.selectedSource, ArtistTracker.ye.rawValue)
        XCTAssertEqual(scout.tracks.count, 2)
        // Typing updates the loaded list without submitting or touching the network.
        TrackerProtocol.reply = { _ in (500, "Network must not be used for typing") }
        XCTAssertTrue(scout.filterTracker("ferrari"))
        XCTAssertEqual(scout.tracks.map(\.title), ["White Ferrari [V2] (feat. James Blake)"])
        XCTAssertTrue(scout.filterTracker("no such track"))
        XCTAssertTrue(scout.tracks.isEmpty)
        XCTAssertTrue(scout.filterTracker(""))
        XCTAssertEqual(scout.tracks.count, 2)
        XCTAssertNil(scout.error)
        await scout.search("ferrari")
        XCTAssertEqual(scout.tracker, .ye, "subsequent submitted queries stay in the tracker")
        XCTAssertEqual(scout.tracks.count, 1)
    }

    func testPartialOutageKeepsAvailableSongsAndReportsMissingTab() async {
        let scout = ScoutService(session: session(failReleased: true))
        await scout.search("ye tracker")
        XCTAssertEqual(scout.tracks.count, 2)
        XCTAssertTrue(scout.error?.contains("Released") == true)
        XCTAssertFalse(scout.loading)
    }

    func testImgurSharePageResolvesBeforePlaybackOrDownload() async throws {
        let audio = try await TrackerAudio.resolve(URL(string: "https://imgur.gg/f/abc123")!, session: session())
        XCTAssertEqual(audio.absoluteString, "https://b.imgur.gg/abc123.mp3")
    }

    func testUnavailableTrackerClearsPreviousResults() async {
        let session = session()
        let scout = ScoutService(session: session)
        await scout.search("ye tracker")
        TrackerProtocol.reply = { _ in (404, "Unavailable") }
        await scout.search("kendrick tracker")
        XCTAssertTrue(scout.tracks.isEmpty)
        XCTAssertNotNil(scout.error)
        XCTAssertFalse(scout.loading)
    }

    func testArchiveLengthsAcceptStringAndNumericMetadata() async {
        let scout = ScoutService(session: session())
        await scout.open(ScoutCollection(identifier: "timed-album", title: "Timed album"))
        XCTAssertNil(scout.error)
        XCTAssertEqual(scout.tracks.first(where: { $0.title == "One" })?.duration, 222.5)
        XCTAssertEqual(scout.tracks.first(where: { $0.title == "Two" })?.duration, 123.75)
        XCTAssertNil(scout.tracks.first(where: { $0.title == "Three" })?.duration)
    }
}
