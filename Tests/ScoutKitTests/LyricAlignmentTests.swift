import XCTest
@testable import ScoutKit

final class LyricAlignmentTests: XCTestCase {
    private func word(_ text: String, _ start: Double) -> TimedLyricWord { .init(start: start, end: start + 0.3, text: text) }
    func testWrittenLyricsTakeRecognizedTimesAndKeepTheirSpelling() {
        let lines = [LyricAlignment.Line(time: 10, text: "I'm gonna run away"), .init(time: 14, text: "Never coming back")]
        let heard = [word("I'm", 10.2), word("going", 10.5), word("run", 10.9), word("away", 11.3), word("never", 14.1), word("comin", 14.5), word("back", 14.9)]
        let result = LyricAlignment.align(lines, recognized: heard)
        XCTAssertEqual(result.lines[0].map(\.text), ["I'm", "gonna", "run", "away"])
        XCTAssertEqual(result.lines[1].map(\.text), ["Never", "coming", "back"])
        XCTAssertEqual(result.lines[0][2].start, 10.9, accuracy: 0.001)
        XCTAssertEqual(result.lines[1][1].start, 14.5, accuracy: 0.001)
        XCTAssertGreaterThan(result.matched, 0.8)
    }
    func testMissedWordIsInterpolatedBetweenItsNeighbours() {
        let lines = [LyricAlignment.Line(time: nil, text: "hold me closer tonight")]
        let result = LyricAlignment.align(lines, recognized: [word("hold", 5), word("me", 5.4), word("tonight", 6.6)])
        let closer = result.lines[0][2]
        XCTAssertEqual(closer.text, "closer")
        XCTAssertGreaterThanOrEqual(closer.start, 5.7 - 0.001); XCTAssertLessThanOrEqual(closer.end, 6.6 + 0.001)
        let starts = result.lines[0].map(\.start)
        XCTAssertEqual(starts, starts.sorted())
    }
    func testRepeatedChorusWordsStayInTheirOwnVerse() {
        let lines = [LyricAlignment.Line(time: 10, text: "oh oh"), .init(time: 60, text: "oh oh")]
        let heard = [word("oh", 10), word("oh", 10.5), word("oh", 60.1), word("oh", 60.6)]
        let result = LyricAlignment.align(lines, recognized: heard)
        XCTAssertEqual(result.lines[1][0].start, 60.1, accuracy: 0.001)
        XCTAssertEqual(result.lines[0][1].start, 10.5, accuracy: 0.001)
    }
    func testOutputRoundTripsThroughTheParser() {
        let result = LyricAlignment.align([.init(time: 1, text: "one two")], recognized: [word("one", 1), word("two", 1.5)])
        let parsed = LyricsParser.parse(result.lrc)
        XCTAssertEqual(parsed.first?.words.map(\.text), ["one", "two"])
        XCTAssertEqual(parsed.first?.time ?? -1, 1, accuracy: 0.001)
    }
}

