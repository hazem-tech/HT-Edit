//
//  ReadmeScreenshots.swift
//  HT EditUITests
//
//  Captures the screenshots shown in README.md. Each one is attached to the
//  result bundle as "readme-<name>"; `.github/workflows/screenshots.yml`
//  exports them to docs/screenshots/<name>.png and commits them.
//
//  Run locally: ⌘U with only this class selected, then open the result
//  bundle's attachments.
//

import XCTest

final class ReadmeScreenshots: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The editor before anything is imported.
    @MainActor
    func testEmptyState() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["importButton"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 0.5)
        capture(app, as: "empty-state")
    }

    /// Two landscape clips on one timeline: the clip sidebar, the clip-boundary
    /// line, highlighted silences and the live settings.
    @MainActor
    func testLandscapeTimeline() throws {
        let app = launchAndWaitForAnalysis(fixtures: "h264Landscape,h264Landscape", clips: 2)
        capture(app, as: "landscape")
    }

    /// A vertical video: the player sits beside the timeline.
    @MainActor
    func testPortraitLayout() throws {
        let app = launchAndWaitForAnalysis(fixtures: "portrait", clips: 1)
        capture(app, as: "portrait")
    }

    // MARK: Helpers

    @MainActor
    private func launchAndWaitForAnalysis(fixtures: String, clips: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixture", fixtures]
        app.launch()

        let rows = app.descendants(matching: .any).matching(identifier: "clipRow")
        XCTAssertTrue(rows.element(boundBy: clips - 1).waitForExistence(timeout: 30), "Clips didn't appear")

        let analyzing = app.staticTexts["Analyzing audio…"]
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: analyzing)
        XCTAssertEqual(XCTWaiter().wait(for: [finished], timeout: 30), .completed, "Still analyzing")

        let player = app.descendants(matching: .any).matching(identifier: "playerView").firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10), "Player view not found")

        // Let the first frame and the waveform finish drawing.
        Thread.sleep(forTimeInterval: 1.5)
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, as name: String) {
        let window = app.windows.firstMatch
        let screenshot = window.exists ? window.screenshot() : app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot, quality: .original)
        attachment.name = "readme-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
