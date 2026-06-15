//
//  FrontCameraContinuationApp.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//

import AppIntents
import SwiftUI

@main
struct FrontCameraContinuationApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = ContentViewModel()
    @State private var launchCoordinator = StreamingLaunchCoordinator.shared

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .task(id: launchCoordinator.pendingStartRequestID,
                      viewModel.startStreamingFromAppIntent)
                .task(id: scenePhase) {
                    guard scenePhase == .active else {
                        return
                    }

                    viewModel.startStreamingFromAppIntent()
                }
                .task {
                    Cam2MacAppShortcuts.updateAppShortcutParameters()
                }
        }
    }
}
