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

    /// Imports a generated video (green frames, tone/silence/tone) via the debug hook.
    @MainActor
    private func launchWithFixture(_ kinds: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFixture"] + kinds
        app.launch()
        return app
    }

    @MainActor
    func testImportedVideoShowsFramesAndFinishesAnalyzing() throws {
        let app = launchWithFixture("h264Landscape")

        let row = app.descendants(matching: .any).matching(identifier: "clipRow").firstMatch
        expect(row.waitForExistence(timeout: 20), "Clip row didn't appear", app)

        // "Analyzing audio…" must go away.
        let analyzing = app.staticTexts["Analyzing audio…"]
        let finished = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: finished, object: analyzing)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 20), .completed, "Still analyzing after 20 s")

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
        let row = app.descendants(matching: .any).matching(identifier: "clipRow").firstMatch
        expect(row.waitForExistence(timeout: 20), "Clip row didn't appear", app)

        let addButton = app.buttons["addButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()
        XCTAssertTrue(waitForOpenPanel(in: app), "Open panel didn't appear from + with media loaded")
    }

    @MainActor
    func testRightClickDeleteRemovesClip() throws {
        let app = launchWithFixture("h264Landscape", "hevcMP4")
        let rows = app.descendants(matching: .any).matching(identifier: "clipRow")
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
        let row = app.descendants(matching: .any).matching(identifier: "clipRow").firstMatch
        expect(row.waitForExistence(timeout: 20), "Clip row didn't appear", app)

        row.click()
        app.typeKey(.delete, modifierFlags: [])

        expect(app.buttons["importButton"].waitForExistence(timeout: 5), "Deleting the only clip should return to the empty state", app)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    // MARK: Helpers

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
