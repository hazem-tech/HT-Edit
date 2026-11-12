//
//  HT_EditUITests.swift
//  HT EditUITests
//
//  Created by Hazem on 10/31/26.
//

import XCTest

final class HT_EditUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Launch & import button

    /// The splash screen warms up the media pipeline, then the editor appears.
    @MainActor
    func testLaunchShowsImportButtonAfterSplash() throws {
        let app = XCUIApplication()
        app.launch()

        let importButton = app.buttons["importButton"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        XCTAssertTrue(importButton.isEnabled)
    }

    @MainActor
    func testEmptyStateImportButtonOpensFilePicker() throws {
        let app = XCUIApplication()
        app.launch()

        let importButton = app.buttons["importButton"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        importButton.click()
        XCTAssertTrue(waitForOpenPanel(in: app), "Open panel didn't appear from the empty-state button")
    }

    @MainActor
    func testToolbarAddButtonOpensFilePicker() throws {
        let app = XCUIApplication()
        app.launch()

        let addButton = app.buttons["addButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10))
        addButton.click()
        XCTAssertTrue(waitForOpenPanel(in: app), "Open panel didn't appear from the toolbar + button")
    }

    // MARK: Imported media

    /// Imports a generated video (green frames, tone/silence/tone) via the debug
    /// hook. Imports transcribe automatically, so the built-in fake stands in
    /// for Antigravity: UI tests never run the real `agy`.
    @MainActor
    private func launchWithFixture(_ kinds: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixture", kinds.joined(separator: ","), "-UITestFakeTranscription", "1"]
        app.launch()
        return app
    }

    @MainActor
    func testImportedVideoShowsFramesAndFinishesAnalyzing() throws {
        let app = launchWithFixture("h264Landscape")

        expect(app.timeline.waitForExistence(timeout: 20), "Timeline didn't appear", app)
        expect(!app.clipRows.firstMatch.exists, "The clip sidebar should start hidden", app)

        // "Analyzing audio…" must go away.
        let analyzing = app.staticTexts["Analyzing audio…"]
        let finished = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: finished, object: analyzing)
        expect(XCTWaiter().wait(for: [expectation], timeout: 20) == .completed, "Still analyzing after 20 s", app)

        // The player area shows the green video, not black.
        let player = app.descendants(matching: .any).matching(identifier: "playerView").firstMatch
        expect(player.waitForExistence(timeout: 10), "Player view not found", app)
        let start = Date()
        var green = 0.0
        repeat {
            green = greenFraction(of: player.screenshot().image)
            if green > 0.3 { break }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date().timeIntervalSince(start) < 10
        add(XCTAttachment(screenshot: app.screenshot()))
        expect(green > 0.3, "Player area isn't showing the video (green fraction \(green))", app)
    }

    @MainActor
    func testToolbarAddButtonOpensFilePickerWithMediaLoaded() throws {
        let app = launchWithFixture("h264Landscape")
        expect(app.timeline.waitForExistence(timeout: 20), "Timeline didn't appear", app)

        let addButton = app.buttons["addButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()
        XCTAssertTrue(waitForOpenPanel(in: app), "Open panel didn't appear from + with media loaded")
    }

    @MainActor
    func testRightClickDeleteRemovesClip() throws {
        let app = launchWithFixture("h264Landscape", "h264Landscape")
        expect(app.timeline.waitForExistence(timeout: 30), "Timeline didn't appear", app)
        app.showSidebar()
        let rows = app.clipRows
        expect(rows.element(boundBy: 1).waitForExistence(timeout: 30), "Both clips should appear", app)
        XCTAssertEqual(rows.count, 2)

        rows.element(boundBy: 0).rightClick()
        let delete = app.menuItems["Delete Clip"]
        expect(delete.waitForExistence(timeout: 5), "Context menu has no Delete item", app)
        delete.click()

        let oneLeft = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 1"), object: rows)
        XCTAssertEqual(XCTWaiter().wait(for: [oneLeft], timeout: 5), .completed, "Clip wasn't deleted")
    }

    @MainActor
    func testDeleteKeyRemovesSelectedClip() throws {
        let app = launchWithFixture("h264Landscape")
        expect(app.timeline.waitForExistence(timeout: 20), "Timeline didn't appear", app)
        app.showSidebar()
        let row = app.clipRows.firstMatch
        expect(row.waitForExistence(timeout: 10), "Clip row didn't appear", app)

        row.click()
        app.typeKey(.delete, modifierFlags: [])

        expect(app.buttons["importButton"].waitForExistence(timeout: 5), "Deleting the only clip should return to the empty state", app)
    }

    // MARK: Transcript

    /// With the fake transcriber (no Google sign-in needed): importing fills in
    /// the transcript by itself, with the cheapest model. There's no Transcribe
    /// button and no context field, and Retry only shows after a failure. The
    /// transcript sits below the silence settings, in the same inspector.
    @MainActor
    func testTranscriptionStartsAutomatically() throws {
        let app = launchWithFixture("h264Landscape")
        expect(app.timeline.waitForExistence(timeout: 20), "Timeline didn't appear", app)

        expect(!app.radioButtons["Transcript"].exists && !app.buttons["Transcript"].exists, "There should be no inspector tabs", app)
        let speechToggle = app.descendants(matching: .any).matching(identifier: "cutNonSpeechToggle").firstMatch
        expect(speechToggle.waitForExistence(timeout: 5), "Silence settings should be in the inspector", app)

        let line = transcriptRow(in: app)
        expect(line.exists, "No transcript rows after importing", app)

        let picker = app.descendants(matching: .any).matching(identifier: "transcriptModelPicker").firstMatch
        expect(picker.waitForExistence(timeout: 5), "Model picker not found", app)
        let pickerValue = (picker.value as? String) ?? picker.label
        expect(pickerValue.contains("(cheapest)"), "Picker should default to the cheapest model, shows \(pickerValue)", app)

        expect(!app.buttons["transcribeButton"].exists, "There should be no Transcribe button", app)
        expect(!app.descendants(matching: .any).matching(identifier: "transcriptContextField").firstMatch.exists, "There should be no context field", app)
        expect(!app.buttons["transcriptRetryButton"].exists, "Retry should only show after a failure", app)
        add(XCTAttachment(screenshot: app.screenshot()))
    }

    /// A preset question highlights words (the fake review picks the first
    /// one), Select selects them, and the toolbar has Full/Clean and Export.
    @MainActor
    func testReviewPresetHighlightsWordsAndLayoutSwitches() throws {
        let app = launchWithFixture("h264Landscape")
        expect(app.timeline.waitForExistence(timeout: 20), "Timeline didn't appear", app)
        expect(transcriptRow(in: app).exists, "No transcript rows after importing", app)

        let presets = app.descendants(matching: .any).matching(identifier: "reviewPresetsMenu").firstMatch
        expect(presets.waitForExistence(timeout: 5), "Presets menu not found", app)
        presets.click()
        let item = app.menuItems["Find repetition"]
        expect(item.waitForExistence(timeout: 3), "Preset menu item not found", app)
        item.click()

        let summary = app.staticTexts["reviewSummary"]
        expect(summary.waitForExistence(timeout: 10), "The review didn't answer", app)
        let summaryText = (summary.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? summary.label
        expect(summaryText.contains("1 highlight"), "Expected one highlight, shows \(summaryText)", app)
        app.buttons["reviewSelectButton"].click()
        let deleteButton = app.buttons["deleteWordsButton"]
        expect(deleteButton.waitForExistence(timeout: 3) && deleteButton.isEnabled, "Select should select the highlighted words", app)

        let layout = app.descendants(matching: .any).matching(identifier: "layoutPicker").firstMatch
        expect(layout.waitForExistence(timeout: 5), "Layout switch not found", app)
        let clean = [app.radioButtons["Clean"], app.buttons["Clean"]].first { $0.exists }
        expect(clean != nil, "Clean option not found", app)
        clean?.click()
        expect(app.timeline.exists, "Timeline is gone in Clean", app)
        expect(app.buttons["exportButton"].isEnabled, "Export should be enabled with a clip", app)
        add(XCTAttachment(screenshot: app.screenshot()))
    }

    // MARK: Zoom

    /// Dragging the zoom slider fast with the playhead midway through the
    /// timeline used to crash (at the first frame it never did).
    @MainActor
    func testZoomSliderDraggedFastWithThePlayheadMidway() throws {
        let app = launchWithFixture("h264Landscape", "h264Landscape")
        expect(app.timeline.waitForExistence(timeout: 30), "Timeline didn't appear", app)
        let analyzing = app.staticTexts["Analyzing audio…"]
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: analyzing)], timeout: 30)

        // Put the playhead in the middle of the timeline.
        app.timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).click()

        let slider = app.sliders["zoomSlider"]
        expect(slider.waitForExistence(timeout: 5), "Zoom slider not found", app)
        let left = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
        let right = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5))
        for round in 0..<8 {
            if round.isMultiple(of: 2) {
                left.click(forDuration: 0.05, thenDragTo: right)
            } else {
                right.click(forDuration: 0.05, thenDragTo: left)
            }
        }
        for position in [0.9, 0.1, 1, 0, 0.6, 0.3, 0.95, 0.05, 0.75, 0.25, 1, 0.5, 0, 0.8, 0.2] {
            slider.adjust(toNormalizedSliderPosition: CGFloat(position))
        }

        expect(app.state == .runningForeground, "The app quit while zooming", app)
        expect(app.timeline.exists, "Timeline is gone after zooming", app)
    }

    // MARK: Keyboard

    /// Space plays even while the clip list has keyboard focus (a list would
    /// otherwise take the space for type-to-select).
    @MainActor
    func testSpaceTogglesPlaybackWhenTheClipListHasFocus() throws {
        let app = launchWithFixture("h264Landscape")
        expect(app.timeline.waitForExistence(timeout: 20), "Timeline didn't appear", app)
        app.showSidebar()
        let row = app.clipRows.firstMatch
        expect(row.waitForExistence(timeout: 10), "Clip row didn't appear", app)
        row.click()

        let time = app.staticTexts["transportTime"]
        expect(time.waitForExistence(timeout: 5), "Time label not found", app)
        let playPause = app.buttons["playPauseButton"]
        let shownTime = { (time.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? time.label }
        let before = shownTime()
        app.typeKey(" ", modifierFlags: [])

        // Playback is short (the fixture's speech is under a second), so poll
        // for either sign that it started: the pause button, or a new time.
        let deadline = Date().addingTimeInterval(5)
        var started = false
        while !started, Date() < deadline {
            started = playPause.label == "Pause" || shownTime() != before
            if !started { Thread.sleep(forTimeInterval: 0.1) }
        }
        expect(started, "Space didn't start playback (time stayed \(before))", app)
        expect(app.clipRows.count == 1, "Space must not touch the clip list", app)
    }

    // MARK: Helpers

    /// The first transcript line, once it's there. The transcript sits below
    /// the silence settings, so scroll the inspector down if it's out of view.
    @MainActor
    private func transcriptRow(in app: XCUIApplication) -> XCUIElement {
        let line = app.descendants(matching: .any).matching(identifier: "transcriptRow").firstMatch
        if line.waitForExistence(timeout: 20) { return line }
        let settings = app.descendants(matching: .any).matching(identifier: "cutNonSpeechToggle").firstMatch
        if settings.exists {
            settings.scroll(byDeltaX: 0, deltaY: -1500)
        }
        _ = line.waitForExistence(timeout: 10)
        return line
    }

    /// Asserts, and on failure prints the app's accessibility tree into the test log
    /// so CI shows what was on screen (alerts, missing views, wrong state).
    @MainActor
    private func expect(_ condition: Bool, _ message: String, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        if !condition {
            print("---- UI hierarchy at failure: \(message) ----\n\(app.debugDescription)\n---- end hierarchy ----")
            add(XCTAttachment(screenshot: app.screenshot()))
        }
        XCTAssertTrue(condition, message, file: file, line: line)
    }

    @MainActor
    private func waitForOpenPanel(in app: XCUIApplication) -> Bool {
        let candidates = [app.sheets.firstMatch, app.dialogs.firstMatch, app.windows["Open"]]
        let start = Date()
        while Date().timeIntervalSince(start) < 8 {
            if candidates.contains(where: \.exists) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// Fraction of sampled pixels that are clearly green (the fixture's frame color).
    private func greenFraction(of image: NSImage) -> Double {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let width = 48, height = 48
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var greenCount = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
            if green > 120 && green > red + 60 && green > blue + 60 { greenCount += 1 }
        }
        return Double(greenCount) / Double(width * height)
    }
}
