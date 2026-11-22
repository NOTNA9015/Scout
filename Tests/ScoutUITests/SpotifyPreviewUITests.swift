import XCTest

/// Drives the real Spotify (Chroma + Scout, installed in the simulator) to look at screens; skipped
/// unless asked for. Steps are separated by ";": tap:<id or label>, tapxy:<x>,<y> (points),
/// type:<text>, wait:<seconds>, shot:<name>, swipeup, swipedown, swipeleft, swiperight.
///
///     TEST_RUNNER_SCOUT_STEPS='shot:home;tap:Your Library;shot:library' TEST_RUNNER_SCOUT_OUT=/some/folder \
///     TEST_RUNNER_SCOUT_RELAUNCH=1 TEST_RUNNER_SCOUT_ARGS='-ScoutOpen menu' \
///     xcodebuild … test -only-testing:ScoutUITests/SpotifyPreviewUITests
///
/// Each shot saves <n>-<name>.png and the element tree as <n>-<name>.txt in SCOUT_OUT.
final class SpotifyPreviewUITests: XCTestCase {
    func testPreview() throws {
        let env = ProcessInfo.processInfo.environment
        guard let steps = env["SCOUT_STEPS"], let out = env["SCOUT_OUT"] else { throw XCTSkip("Preview only: set SCOUT_STEPS and SCOUT_OUT.") }
        let app = XCUIApplication(bundleIdentifier: "com.spotify.client")
        if env["SCOUT_RELAUNCH"] == "1" {
            app.terminate()
            app.launchArguments = (env["SCOUT_ARGS"] ?? "").split(separator: " ").map(String.init)
            app.launch()
        } else {
            app.activate()
        }
        var count = 0
        for step in steps.split(separator: ";") {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "tap": element(argument, in: app).tap()
            case "tapxy":
                let xy = argument.split(separator: ",").compactMap { Double($0) }
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: xy[0], dy: xy[1])).tap()
            case "type": app.typeText(argument)
            case "wait": Thread.sleep(forTimeInterval: Double(argument) ?? 1)
            case "swipeup": app.swipeUp()
            case "swipedown": app.swipeDown()
            case "swipeleft": app.swipeLeft()
            case "swiperight": app.swipeRight()
            case "shot":
                count += 1
                let base = URL(fileURLWithPath: out).appendingPathComponent(String(format: "%02d-%@", count, argument))
                try app.screenshot().pngRepresentation.write(to: base.appendingPathExtension("png"))
                try app.debugDescription.write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            default: XCTFail("Unknown step \(step)")
            }
        }
    }

    private func element(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let match = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@", name, name)).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 15), "Nothing called \(name)")
        return match
    }
}
