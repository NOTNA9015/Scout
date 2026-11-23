import XCTest

final class ScoutUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["-ScoutFixtures"]; app.launch(); return app
    }
    private func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func next(_ app: XCUIApplication) { let button = app.buttons["scout.next"]; XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap() }

    func testHeaderButtonOpensTheMenu() {
        let app = launch()
        let entry = app.buttons["scout.entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        shot("Your Library", app)
        entry.tap()
        XCTAssertTrue(app.buttons["scout.menu.song"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["scout.menu.album"].exists)
        // No Chroma in this app, so Scout's own menu keeps Updates.
        XCTAssertTrue(app.buttons["scout.menu.updates"].exists)
        shot("Menu", app)
    }

    func testConverterIsAvailableFromScoutMenu() {
        let app = launch()
        app.buttons["scout.entry"].tap()
        app.buttons["scout.menu.converter"].tap()
        XCTAssertTrue(app.buttons["scout.converter.choose"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["scout.converter.convert"].exists)
        XCTAssertFalse(app.buttons["scout.converter.convert"].isEnabled)
        shot("File converter", app)
    }

    func testEditImportsHasSongAndAlbumTabs() {
        let app = launch()
        app.buttons["scout.entry"].tap()
        let edit = app.buttons["scout.menu.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(app.segmentedControls["scout.editor.tabs"].waitForExistence(timeout: 5))
        app.segmentedControls["scout.editor.tabs"].buttons["Albums"].tap()
        shot("Edit imports: albums", app)
        app.segmentedControls["scout.editor.tabs"].buttons["Songs"].tap()
        // Songs imported by earlier tests in this simulator can be opened and edited.
        let song = app.buttons["scout.editor.song"].firstMatch
        if song.waitForExistence(timeout: 2) {
            song.tap()
            XCTAssertTrue(app.textFields["scout.editor.title"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["scout.editor.save"].exists)
            shot("Edit a song", app)
        }
    }

    func testTrackerLiveFilteringAndPreviewStopsWhenScrolledAway() {
        let app = XCUIApplication(); app.launchArguments = ["-ScoutSearchFixtures"]; app.launch()
        app.buttons["scout.entry"].tap()
        app.buttons["scout.menu.song"].tap()
        let query = app.textFields["scout.search.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        query.tap(); query.typeText("ye tracker\n")
        let ghost = app.buttons["Preview Ghost Town [V1]"]
        let runaway = app.buttons["Preview Runaway [V2]"]
        XCTAssertTrue(ghost.waitForExistence(timeout: 5))
        XCTAssertTrue(runaway.exists)
        query.tap(); query.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10)); query.typeText("ghost")
        XCTAssertTrue(ghost.waitForExistence(timeout: 3))
        XCTAssertTrue(NSPredicate(format: "exists == false").evaluate(with: runaway))
        shot("Live tracker filtering", app)
        app.buttons["Clear search"].tap()
        query.tap(); query.typeText("\n")
        XCTAssertTrue(runaway.waitForExistence(timeout: 3), "clearing the filter restores the same tracker")
        ghost.tap()
        XCTAssertTrue(app.staticTexts["Downloading preview"].waitForExistence(timeout: 2))
        shot("Preview loading", app)
        XCTAssertTrue(app.buttons["Pause preview"].waitForExistence(timeout: 6))
        shot("Inline preview player", app)
        app.swipeUp(); app.swipeUp()
        XCTAssertFalse(app.buttons["Pause preview"].exists)
        XCTAssertFalse(app.buttons["Play preview"].exists)
    }

    func testSingleSongImport() {
        let app = launch()
        app.buttons["scout.entry"].tap()
        app.buttons["scout.menu.song"].tap()
        // Name: several options, pick the clean one.
        XCTAssertTrue(app.staticTexts["Song name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(identifier: "scout.track.length").firstMatch.exists)
        // Rows read "name, detail" to VoiceOver; match the name at the start.
        let clean = app.buttons.matching(NSPredicate(format: "label == 'Night Bus' OR label BEGINSWITH 'Night Bus,'")).firstMatch
        XCTAssertTrue(clean.waitForExistence(timeout: 5)); clean.tap()
        shot("Song name", app)
        next(app)
        // Artists: the featured artist from the title is suggested.
        XCTAssertTrue(app.staticTexts["Artists"].waitForExistence(timeout: 5))
        let featured = app.buttons["Juno Reyes"].firstMatch
        XCTAssertTrue(featured.waitForExistence(timeout: 5)); featured.tap()
        XCTAssertEqual(app.staticTexts["scout.artists.current"].label, "Ines Vale, Juno Reyes")
        shot("Artists", app)
        next(app)
        XCTAssertTrue(app.staticTexts["Cover"].waitForExistence(timeout: 5))
        next(app)
        // Lyrics: every candidate shown; Scout listens and generates word-timed lyrics, its default.
        let verdict = app.staticTexts["scout.lyrics.verdict"]
        XCTAssertTrue(verdict.waitForExistence(timeout: 10))
        XCTAssertTrue(verdict.label.hasPrefix("Recommended: generated"), verdict.label)
        XCTAssertTrue(app.staticTexts["Recommended"].exists)
        let generated = app.staticTexts["Fixture, timed to your audio"]
        XCTAssertTrue(generated.waitForExistence(timeout: 3), "sung as the lyric found is written: that lyric, every word timed")
        shot("Lyrics", app)
        // The setup steps are lists, which only build the rows on screen: scroll to the lyrics found.
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Plain text"].waitForExistence(timeout: 3))
        // Another pick is one tap away; a line-timed one is offered word timing.
        app.staticTexts["Line-timed"].tap()
        app.swipeUp()
        let words = app.switches["scout.lyrics.timewords"]
        XCTAssertTrue(words.waitForExistence(timeout: 3), "word timing is offered for the line-timed pick")
        app.swipeDown(); app.swipeDown()
        generated.tap()
        app.swipeUp()
        XCTAssertFalse(words.waitForExistence(timeout: 1), "generated lyrics are already word-timed")
        next(app)
        let summary = app.staticTexts["scout.done.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
        XCTAssertEqual(summary.label, "1 song saved")
        shot("Done", app)
    }

    func testAlbumImportGeneratesLyricsAndRecordsAPendingPlaylist() {
        let app = launch()
        app.buttons["scout.entry"].tap()
        app.buttons["scout.menu.album"].tap()
        XCTAssertTrue(app.staticTexts["Song 1 of 3"].waitForExistence(timeout: 5))
        next(app); next(app); next(app)                      // names, one page per song
        XCTAssertTrue(app.staticTexts["Lyrics"].waitForExistence(timeout: 5))
        for _ in 0..<3 {                                      // lyrics per song; none online for song 2
            _ = app.staticTexts["scout.lyrics.verdict"].waitForExistence(timeout: 10)
            next(app)
        }
        // No prompt for the song without lyrics online: its lyrics are generated like the others'.
        XCTAssertTrue(app.staticTexts["Artists"].waitForExistence(timeout: 5))
        next(app); next(app); next(app)                      // artists per song
        XCTAssertTrue(app.staticTexts["The album"].waitForExistence(timeout: 5))
        shot("Album", app)
        next(app)                                             // Import
        let summary = app.staticTexts["scout.done.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 60))
        XCTAssertEqual(summary.label, "3 songs saved")
        let status = app.staticTexts["scout.playlist.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), "the album shows its playlist status")
        XCTAssertTrue(status.label.hasPrefix("Done."), status.label)
        shot("Album done", app)
        app.buttons["scout.done.close"].tap()
        // Local Files gets the button that makes the waiting album into a playlist.
        XCTAssertTrue(app.buttons["harness.localfiles"].waitForExistence(timeout: 5))
        app.buttons["harness.localfiles"].tap()
        let compile = app.buttons["scout.compile"]
        XCTAssertTrue(compile.waitForExistence(timeout: 5))
        XCTAssertTrue(compile.label.contains("Compile pending playlists ("), compile.label)  // earlier runs may have left more
        shot("Local Files", app)
        compile.tap()
        let made = app.alerts.matching(NSPredicate(format: "label CONTAINS 'made'")).firstMatch
        XCTAssertTrue(made.waitForExistence(timeout: 10))
        made.buttons["OK"].tap()
        XCTAssertTrue(compile.label.hasSuffix("Compile pending playlists"), compile.label)
    }

    func testQuickSetupEverythingImportsTheAlbumInOneTap() {
        let app = launch()
        app.buttons["scout.entry"].tap()
        app.buttons["scout.menu.album"].tap()
        XCTAssertTrue(app.staticTexts["Song 1 of 3"].waitForExistence(timeout: 5))
        let quick = app.buttons["scout.quick.all"]
        XCTAssertTrue(quick.waitForExistence(timeout: 5))
        shot("Quick setup everything", app)
        quick.tap()
        let summary = app.staticTexts["scout.done.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 90))
        XCTAssertEqual(summary.label, "3 songs saved")
        shot("Quick done", app)
    }
}
