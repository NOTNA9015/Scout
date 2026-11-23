import XCTest
@testable import ScoutKit

final class SegmentedDownloadTests: XCTestCase {
    func testPlanCoversEveryByteInOrder() {
        for size: Int64 in [1, 1_499_999, 1_500_000, 1_500_001, 7_000_000, 9_438_548, 44_564_991, 63_109_280] {
            let (ranges, connections) = SegmentedDownload.plan(size: size)
            XCTAssertEqual(ranges.first?.lowerBound, 0)
            XCTAssertEqual(ranges.last?.upperBound, size - 1)
            for (before, after) in zip(ranges, ranges.dropFirst()) { XCTAssertEqual(after.lowerBound, before.upperBound + 1, "size \(size)") }
            XCTAssertEqual(ranges.first?.count, Int(min(size, SegmentedDownload.minimumRange)), "the first range is asked for before the size is known")
            XCTAssertTrue(ranges.dropLast().allSatisfy { $0.count >= SegmentedDownload.minimumRange })
            XCTAssertEqual(connections, min(SegmentedDownload.maxParts, ranges.count))
        }
        XCTAssertEqual(SegmentedDownload.plan(size: 1_500_000).ranges.count, 1)
        XCTAssertEqual(SegmentedDownload.plan(size: 9_438_548).ranges.count, 7)
        XCTAssertEqual(SegmentedDownload.plan(size: 44_564_991).ranges.count, 12, "about two ranges per connection")
        XCTAssertEqual(SegmentedDownload.plan(size: 44_564_991).connections, 6)
    }

    func testContentRangeAndHosts() {
        XCTAssertEqual(SegmentedDownload.total(contentRange: "bytes 0-1499999/44564991"), 44_564_991)
        XCTAssertNil(SegmentedDownload.total(contentRange: "bytes 0-1499999/*"))
        XCTAssertEqual(SegmentedDownload.start(contentRange: "bytes 1500000-2999999/44564991"), 1_500_000)
        XCTAssertTrue(SegmentedDownload.splits(URL(string: "https://archive.org/download/item/a.mp3")!))
        XCTAssertTrue(SegmentedDownload.splits(URL(string: "https://dn721703.ca.archive.org/0/items/item/a.mp3")!))
        XCTAssertFalse(SegmentedDownload.splits(URL(string: "https://api.pillows.su/api/get/abc")!))
        XCTAssertFalse(SegmentedDownload.splits(URL(string: "https://notarchive.org/a.mp3")!))
    }

    func testRangesAreJoinedIntoTheSameBytes() async throws {
        let server = FakeArchive(size: 7_000_000)
        let (file, http) = try await server.download().download(FakeArchive.address)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), server.data)
        XCTAssertEqual(http.statusCode, 206)
        let asked = server.asked
        XCTAssertEqual(asked.count, SegmentedDownload.plan(size: 7_000_000).ranges.count)
        XCTAssertTrue(asked.dropFirst().allSatisfy { $0.url?.host == FakeArchive.served.host }, "the ranges skip the redirect")
        XCTAssertEqual(server.sizes, [7_000_000])
    }

    func testAFailedRangeIsAskedForAgain() async throws {
        let server = FakeArchive(size: 7_000_000)
        server.failures = ["bytes=3000000-4499999": 1]
        let (file, _) = try await server.download().download(FakeArchive.address)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), server.data)
        XCTAssertEqual(server.asked.filter { $0.value(forHTTPHeaderField: "Range") == "bytes=3000000-4499999" }.count, 2)
    }

    func testASlowRangeIsAskedForAgainOnAnIdleConnection() async throws {
        let server = FakeArchive(size: 7_000_000)
        server.delays = ["bytes=4500000-5999999": .seconds(20)]
        var download = server.download()
        download.patience = .milliseconds(100)
        let clock = ContinuousClock(), start = clock.now
        let (file, _) = try await download.download(FakeArchive.address)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertLessThan(clock.now - start, .seconds(5), "the second copy came in long before the slow one")
        XCTAssertEqual(try Data(contentsOf: file), server.data)
        XCTAssertEqual(server.asked.filter { $0.value(forHTTPHeaderField: "Range") == "bytes=4500000-5999999" }.count, 2)
    }

    func testRangesThatKeepFailingFallBackToOneRequest() async throws {
        let server = FakeArchive(size: 7_000_000)
        server.failures = ["bytes=1500000-2999999": 5]
        let (file, http) = try await server.download().download(FakeArchive.address)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), server.data)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(server.sizes, [7_000_000, nil], "the bar goes back to one file's progress")
    }

    func testAServerThatIgnoresRangesGetsOneRequest() async throws {
        let server = FakeArchive(size: 7_000_000)
        server.ranges = false
        let (file, http) = try await server.download().download(FakeArchive.address)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), server.data)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(server.asked.map { $0.value(forHTTPHeaderField: "Range") }, ["bytes=0-1499999", nil])
        XCTAssertTrue(server.cancelled)
    }

    func testASmallFileIsTheFirstRange() async throws {
        let server = FakeArchive(size: 900_000)
        let (file, http) = try await server.download().download(FakeArchive.address)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), server.data)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(server.asked.count, 1)
    }

    func testOtherHostsAreFetchedWhole() async throws {
        let server = FakeArchive(size: 7_000_000)
        let (file, _) = try await server.download().download(URL(string: "https://api.pillows.su/api/get/0123")!)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(server.asked.map { $0.value(forHTTPHeaderField: "Range") }, [nil])
    }

    func testCancellingStopsTheRanges() async throws {
        let server = FakeArchive(size: 7_000_000)
        server.delays = ["bytes=1500000-2999999": .seconds(20), "bytes=3000000-4499999": .seconds(20)]
        let download = server.download()
        let task = Task { try await download.download(FakeArchive.address) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let clock = ContinuousClock(), start = clock.now
        do { _ = try await task.value; XCTFail("a cancelled download finished") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(clock.now - start, .seconds(2))
    }
}

/// Serves `data` the way the Archive does: the first request is redirected to a download server,
/// ranges are answered with 206 and Content-Range.
private final class FakeArchive: @unchecked Sendable {
    static let address = URL(string: "https://archive.org/download/item/song.mp3")!
    static let served = URL(string: "https://dn000000.ca.archive.org/0/items/item/song.mp3")!

    let data: Data
    var ranges = true
    /// Times a range fails before it is served, and how long it takes when it is.
    var failures: [String: Int] = [:]
    var delays: [String: Duration] = [:]
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var told: [Int64?] = []
    private var stopped = false
    var asked: [URLRequest] { lock.withLock { requests } }
    var sizes: [Int64?] { lock.withLock { told } }
    var cancelled: Bool { lock.withLock { stopped } }

    init(size: Int) {
        var generator = SystemRandomNumberGenerator()
        data = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    func download() -> SegmentedDownload {
        var download = SegmentedDownload(fetch: { [self] request in
            let (body, http) = try await answer(request)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("FakeArchive-" + UUID().uuidString)
            try body.write(to: file)
            return (file, http)
        }, open: { [self] request in
            let (body, http) = try await answer(request)
            return SegmentedDownload.Opened(response: http, body: {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("FakeArchive-" + UUID().uuidString)
                try body.write(to: file)
                return file
            }, cancel: { [self] in lock.withLock { stopped = true } })
        })
        download.sized = { [self] size in lock.withLock { told.append(size) } }
        return download
    }

    private func answer(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let header = request.value(forHTTPHeaderField: "Range")
        let (failing, delay) = lock.withLock { () -> (Bool, Duration?) in
            requests.append(request)
            guard let header else { return (false, nil) }
            let failing = (failures[header] ?? 0) > 0
            if failing { failures[header]! -= 1 }
            return (failing, delays.removeValue(forKey: header))
        }
        if let delay { try await Task.sleep(for: delay) }
        if failing { throw URLError(.networkConnectionLost) }
        let url = request.url == Self.address ? Self.served : request.url!
        guard ranges, let header, let bytes = header.split(separator: "=").last,
              let dash = bytes.firstIndex(of: "-"), let from = Int(bytes[..<dash]), let to = Int(bytes[bytes.index(after: dash)...]) else {
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "audio/mpeg"])!)
        }
        let end = min(to, data.count - 1)
        return (data.subdata(in: from..<(end + 1)), HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                                                                     headerFields: ["Content-Range": "bytes \(from)-\(end)/\(data.count)", "Content-Type": "audio/mpeg"])!)
    }
}
