//
//  HT_EditApp.swift
//  HT Edit
//
//  Created by Hazem on 10/31/26.
//

import AVFoundation
import SwiftUI

@main
struct HT_EditApp: App {
    init() {
        // Lets SwiftUI observe AVPlayer state (e.g. timeControlStatus) via Swift Observation.
        // Must be set before any player is created.
        AVPlayer.isObservationEnabled = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 820)
    }
}
