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
    func testImportButtonOpensFilePicker() throws {
        let app = XCUIApplication()
        app.launch()

        let importButton = app.buttons["importButton"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        importButton.click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5) || app.dialogs.firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
