import XCTest
@testable import ScoutKit

/// Song names come out without emojis and with their capitals fixed; nothing else is touched.
final class SongNameTests: XCTestCase {
    func testEmojisComeOut() {
        XCTAssertEqual(SongName.tidy("⭐ Bully [V1]"), "Bully [V1]")
        XCTAssertEqual(SongName.tidy("Bully 🗑️ [V1]"), "Bully [V1]")
        XCTAssertEqual(SongName.tidy("✨ Pyramids ✨"), "Pyramids")
        XCTAssertEqual(SongName.tidy("Nights (🔥)"), "Nights")
        XCTAssertEqual(SongName.tidy("⭐ - Godspeed"), "Godspeed")
        XCTAssertEqual(SongName.tidy("1️⃣ Ivy"), "Ivy")
        XCTAssertEqual(SongName.tidy("Rock 👍🏽 Roll"), "Rock Roll")
        XCTAssertEqual(SongName.tidy("🇺🇸 Anthem"), "Anthem")
        XCTAssertEqual(SongName.tidy("Family 👨‍👩‍👧 Ties"), "Family Ties")
        XCTAssertEqual(SongName.tidy("I Love You ♥️"), "I Love You")
        XCTAssertEqual(SongName.tidy("🔥🔥"), "🔥🔥", "a name that is only emojis is kept rather than emptied")
    }

    func testTextSymbolsLettersAndDigitsStay() {
        XCTAssertEqual(SongName.tidy("Song #1"), "Song #1")
        XCTAssertEqual(SongName.tidy("I ♥ You"), "I ♥ You")
        XCTAssertEqual(SongName.tidy("Café Del Mar ™"), "Café Del Mar ™")
        XCTAssertEqual(SongName.tidy("夜に駆ける"), "夜に駆ける")
        XCTAssertEqual(SongName.tidy("  Bully   Freestyle "), "Bully Freestyle")
    }

    func testCapitalsAreFixed() {
        XCTAssertEqual(SongName.tidy("new body"), "New Body")
        XCTAssertEqual(SongName.tidy("NEW BODY"), "New Body")
        XCTAssertEqual(SongName.tidy("love on the brain"), "Love on the Brain")
        XCTAssertEqual(SongName.tidy("what you came for"), "What You Came For", "a small word at the end is capitalised")
        XCTAssertEqual(SongName.tidy("don't let me down"), "Don't Let Me Down")
        XCTAssertEqual(SongName.tidy("self-control"), "Self-Control")
        XCTAssertEqual(SongName.tidy("frank ocean - in the morning"), "Frank Ocean - In the Morning")
        XCTAssertEqual(SongName.tidy("bully [v1] (feat. travis scott)"), "Bully [V1] (feat. Travis Scott)")
        XCTAssertEqual(SongName.tidy("FAMOUS (FEAT. RIHANNA)"), "Famous (feat. Rihanna)")
        XCTAssertEqual(SongName.tidy("runaway (prod. by kanye west)"), "Runaway (prod. by Kanye West)")
        XCTAssertEqual(SongName.tidy("DJ KHALED INTRO"), "DJ Khaled Intro")
        XCTAssertEqual(SongName.tidy("ultralight beam pt. ii"), "Ultralight Beam Pt. II")
        XCTAssertEqual(SongName.tidy("a x b"), "A x B")
        XCTAssertEqual(SongName.tidy("Night Bus (feat. juno reyes)"), "Night Bus (feat. Juno Reyes)", "lowercase words in a mixed name are fixed too")
    }

    func testStylisedNamesStay() {
        XCTAssertEqual(SongName.tidy("HUMBLE."), "HUMBLE.", "one word in capitals is stylised")
        XCTAssertEqual(SongName.tidy("DNA."), "DNA.")
        XCTAssertEqual(SongName.tidy("Love On The Brain"), "Love On The Brain", "capitalised words are left as written")
        XCTAssertEqual(SongName.tidy("iPhone love"), "iPhone Love")
        XCTAssertEqual(SongName.tidy("Night Bus (feat. Juno Reyes) [CDQ]"), "Night Bus (feat. Juno Reyes) [CDQ]")
        XCTAssertEqual(SongName.tidy("BULLY [V1]"), "BULLY [V1]")
        XCTAssertEqual(SongName.tidy("2am"), "2am")
    }

    /// A tracker's song: the name is tidied, while the album (the tracker's era) and the artist stay
    /// exactly as the tracker has them.
    @MainActor func testOnlyTheSongNameIsTidied() {
        let track = ScoutTrack(title: "⭐ bully [v1]", artist: "kanye west 🐐", album: "donda 2 🍩", audioURL: "https://x")
        let song = DownloadedSong(file: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mp3"), source: track)
        let draft = SongDraft(song: song)
        XCTAssertEqual(draft.title, "Bully [V1]")
        XCTAssertEqual(draft.album, "donda 2 🍩")
        XCTAssertEqual(draft.artists, ["kanye west 🐐"])
        XCTAssertEqual(Suggestions.nameOptions(for: song, matches: []).first, "Bully [V1]")
        XCTAssertEqual(ScoutFlow.quickName(draft), "Bully")

        // A catalog's official spelling is offered as it is.
        let official = [CatalogMatch(title: "HUMBLE.", artists: ["Kendrick Lamar"], album: "DAMN.", coverURL: nil, source: "T")]
        XCTAssertTrue(Suggestions.nameOptions(for: song, matches: official).contains("HUMBLE."))
    }
}
