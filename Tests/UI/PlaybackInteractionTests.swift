import XCTest

final class PlaybackInteractionTests: XCTestCase {
    @MainActor
    func testPlayAndShareHaveIndependentTapTargets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--demo-detail", "--playback-ui-test", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let play = app.buttons["audio-play-0"]
        for _ in 0..<8 {
            if play.exists && play.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertTrue(play.isHittable)
        XCTAssertEqual(play.label, "播放片段 1")

        play.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "audio-play-0").matching(NSPredicate(format: "label == %@", "停止片段 1")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.otherElements["ActivityListView"].exists, "Play must not present the share sheet")
        play.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "audio-play-0").matching(NSPredicate(format: "label == %@", "播放片段 1")).firstMatch.waitForExistence(timeout: 5))

        app.buttons["audio-share-0"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 20), app.debugDescription)
        // The native activity presentation keeps the underlying playback state accessible.
        XCTAssertEqual(play.label, "播放片段 1")
        app.terminate()
    }
}
