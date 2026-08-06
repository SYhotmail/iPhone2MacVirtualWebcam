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
    @State private var launchResult: Result<ContentViewModel, Error>

    init() {
        launchResult = Result {
            try ContentViewModel()
        }
    }
    
    var body: some Scene {
        WindowGroup {
            Group {
                if let viewModel = launchResult.value {
                    ContentView(viewModel: viewModel)
                        .task(id: viewModel.pendingStartRequestID,
                              viewModel.startStreamingFromAppIntent)
                        .task(id: scenePhase) {
                            guard scenePhase == .active else {
                                return
                            }
                            viewModel.startStreamingFromAppIntent()
                        }
                } else if let error = launchResult.error {
                    Text(error.localizedDescription)
                        .padding()
                }
            }
        }
    }
}
