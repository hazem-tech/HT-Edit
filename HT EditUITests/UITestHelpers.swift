//
//  UITestHelpers.swift
//  HT EditUITests
//

import XCTest

@MainActor
extension XCUIApplication {
    /// The timeline, which appears once a clip is imported.
    var timeline: XCUIElement {
        descendants(matching: .any).matching(identifier: "timeline").firstMatch
    }

    var clipRows: XCUIElementQuery {
        descendants(matching: .any).matching(identifier: "clipRow")
    }

    /// Shows the clip sidebar, which is hidden at launch: ⌃⌘S, or View ▸ Show Sidebar.
    func showSidebar() {
        let row = clipRows.firstMatch
        guard !row.exists else { return }
        typeKey("s", modifierFlags: [.control, .command])
        if row.waitForExistence(timeout: 3) { return }
        menuBars.menuBarItems["View"].click()
        let item = menuItems["Show Sidebar"]
        if item.waitForExistence(timeout: 2) {
            item.click()
        } else {
            typeKey(.escape, modifierFlags: [])
        }
    }
}
