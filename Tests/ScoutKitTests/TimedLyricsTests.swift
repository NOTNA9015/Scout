import XCTest
@testable import ScoutKit

final class TimedLyricsTests: XCTestCase {
    func testEnhancedLRCKeepsWordTimesAndInstrumentalGaps() {
        let words: [TimedLyricWord] = [.init(start: 1.2, end: 1.5, text: "Hello"), .init(start: 1.5, end: 2, text: "world"), .init(start: 12, end: 12.7, text: "Again")]
        let text = TimedLyricWord.enhancedLRC(words)
        let lines = LyricsParser.parse(text)
        XCTAssertEqual(lines.map(\.text), ["Hello world", "Again"])
        XCTAssertEqual(lines.map(\.time), [1.2, 12])
        XCTAssertEqual(lines.flatMap(\.words), words)
    }
    func testEnhancedLRCOffsetsWordsAndRejectsInvalidRecognitionTimes() {
        let text = "[offset:-200]\n[00:01.000]<00:01.000>One <00:01.500>two<00:02.000>"
        let line = LyricsParser.parse(text).first!
        XCTAssertEqual(line.time, 0.8)
        XCTAssertEqual(line.words.map(\.start), [0.8, 1.3])
        XCTAssertEqual(TimedLyricWord.enhancedLRC([.init(start: .nan, end: 2, text: "bad"), .init(start: 1, end: 0, text: "backward")]), "")
        XCTAssertEqual(LyricsParser.parse("[00:01.00]Ordinary line").first?.words, [])
    }
    func testLineOnlyLyricsGetOrderedEstimatedWordsWithinTheLine() {
        let words = TimedLyricWord.estimated("I can feel it coming", start: 10, end: 13)
        XCTAssertEqual(words.map(\.text), ["I", "can", "feel", "it", "coming"])
        XCTAssertEqual(words.first!.start, 10, accuracy: 0.001)
        XCTAssertLessThanOrEqual(words.last!.end, 13.0001)
        XCTAssertTrue(zip(words, words.dropFirst()).allSatisfy { abs($0.end - $1.start) < 0.0001 })
        XCTAssertGreaterThan(words[4].end - words[4].start, words[0].end - words[0].start)
        let beforeBreak = TimedLyricWord.estimated("Short line", start: 0, end: 60)
        XCTAssertLessThan(beforeBreak.last!.end, 5)
        XCTAssertTrue(TimedLyricWord.estimated("   ", start: 0, end: 2).isEmpty)
    }
    func testRecognizerRunsAreSplitCleanedAndMadeMonotonic() {
        let raw: [TimedLyricWord] = [.init(start: 1, end: 2, text: " take me"), .init(start: 2, end: 2.1, text: ","),
                                     .init(start: 2.2, end: 9, text: "home"), .init(start: 2.1, end: 2.3, text: "tonight")]
        let words = TimedLyricWord.refined(raw)
        XCTAssertEqual(words.map(\.text), ["take", "me,", "tonight", "home"])
        XCTAssertEqual(words[0].start, 1, accuracy: 0.001)
        XCTAssertGreaterThan(words[1].start, words[0].start)
        XCTAssertTrue(zip(words, words.dropFirst()).allSatisfy { $0.end <= $1.start + 0.0001 && $0.start <= $1.start })
        XCTAssertLessThan(words.last!.end - words.last!.start, 3)
    }
}
