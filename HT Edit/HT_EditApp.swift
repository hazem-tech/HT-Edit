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
            RootView()
        }
        .defaultSize(width: 1280, height: 820)
    }
}

/// Shows the splash screen until the media pipeline is warm, then the editor.
private struct RootView: View {
    @State private var isReady = false

    var body: some View {
        Group {
            if isReady {
                ContentView()
                    .transition(.opacity)
            } else {
                SplashView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            await WarmUp.run()
            withAnimation(.easeOut(duration: 0.2)) { isReady = true }
        }
    }
}
