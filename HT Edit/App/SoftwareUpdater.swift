//
//  SoftwareUpdater.swift
//  HT Edit
//
//  Updates through Sparkle: the app reads the latest GitHub release's
//  appcast.xml (SUFeedURL in Config/HT-Edit-Info.plist), checks the update's
//  EdDSA signature against SUPublicEDKey, then installs it and relaunches.
//  The release workflow signs every update and writes the appcast.
//

import Sparkle
import SwiftUI

/// Checks for updates in the background, and on demand from
/// HT Edit ▸ Check for Updates…
final class SoftwareUpdater {
    /// Debug builds (and every test run) never check or show update windows.
    #if DEBUG
    static let isEnabled = false
    #else
    static let isEnabled = true
    #endif

    private let controller = SPUStandardUpdaterController(
        startingUpdater: SoftwareUpdater.isEnabled,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func checkForUpdates() {
        guard Self.isEnabled else { return }
        controller.checkForUpdates(nil)
    }
}

/// HT Edit ▸ Check for Updates…, right below About.
struct CheckForUpdatesCommand: Commands {
    let updater: SoftwareUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!SoftwareUpdater.isEnabled)
        }
    }
}
