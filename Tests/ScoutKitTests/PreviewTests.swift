import XCTest
@testable import ScoutKit

@MainActor final class PreviewTests: XCTestCase {
    private func track(_ id: String) -> ScoutTrack { ScoutTrack(title: id, artist: "A", album: "B", audioURL: "https://example.com/\(id).mp3", duration: 1.25) }
    private func song(_ track: ScoutTrack, folder: URL) async throws -> DownloadedSong {
        let original = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "tone", withExtension: "mp3"))
        let file = folder.appendingPathComponent("preview.mp3")
        try FileManager.default.copyItem(at: original, to: file)
        return await DownloadedSong.make(file: file, source: track, artwork: nil)
    }
    private func ready(_ service: ScoutService) async throws {
        for _ in 0..<200 where service.previewLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(service.previewLoading, service.error ?? "still loading")
        XCTAssertNotNil(service.previewTrackID)
    }

    func testPlayerPausesSeeksAndResetsWhenItsRowLeaves() async throws {
        var file: URL?
        let service = ScoutService(previewLoader: { track, folder in
            let song = try await self.song(track, folder: folder); file = song.file; return song
        })
        let track = track("one")
        service.preview(track)
        XCTAssertTrue(service.previewLoading)
        XCTAssertEqual(service.previewProgress, 0)
        try await ready(service)
        XCTAssertGreaterThan(service.previewDuration, 1)
        service.togglePreview()
        XCTAssertFalse(service.previewPlaying)
        service.seekPreview(to: 0.7)
        XCTAssertEqual(service.previewPosition, 0.7, accuracy: 0.001)
        service.stopPreview(matching: "another row")
        XCTAssertEqual(service.previewTrackID, track.id)
        service.stopPreview(matching: track.id)
        XCTAssertNil(service.previewTrackID)
        XCTAssertEqual(service.previewPosition, 0)
        XCTAssertEqual(service.previewDuration, 0)
        XCTAssertFalse(service.previewPlaying)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(file).path))
        service.preview(track)
        try await ready(service)
        XCTAssertLessThan(service.previewPosition, 0.5, "reopening starts from the beginning")
        service.stopPreview()
    }

    func testScrollingAwayWhileLoadingCannotStartPlaybackLater() async throws {
        let service = ScoutService(previewLoader: { track, folder in
            try? await Task.sleep(for: .milliseconds(100))
            return try await self.song(track, folder: folder)
        })
        let track = track("loading")
        service.preview(track)
        service.stopPreview(matching: track.id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(service.previewTrackID)
        XCTAssertFalse(service.previewLoading)
        XCTAssertFalse(service.previewPlaying)
        XCTAssertEqual(service.previewPosition, 0)
    }
}
