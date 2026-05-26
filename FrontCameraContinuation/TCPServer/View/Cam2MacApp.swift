//
//  Cam2MacApp.swift
//  Cam2Mac
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//

import SwiftUI

@main
struct Cam2MacApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var rootVM = ConnectViewModel()
    
    enum Constants {
        static let mainWindowId = "main-window"
        static let quickSetupId = "quick-setup"
    }

    var body: some Scene {
        WindowGroup("Cam2Mac", id: Constants.mainWindowId) {
            ConnectView(viewModel: rootVM)
        }
        .windowManagerRole(.principal)
        .defaultSize(width: 800, height: 640)
        .commands {
            QuickSetupCommands()
        }

        MenuBarExtra {
            ReceiverMenuBarView(
                viewModel: rootVM) {
                    openWindow(id: Constants.mainWindowId)
                }
        } label: {
            ReceiverMenuBarLabelView(viewModel: rootVM)
        }

        WindowGroup("Quick Setup", id: Constants.quickSetupId) {
            QuickSetupView(viewModel: rootVM.provideQuickSetupViewModel())
                .frame(minWidth: 400, maxWidth: 900, minHeight: 400)
        }
        .defaultSize(width: 500, height: 550)
        .windowManagerRole(.associated)
        .restorationBehavior(.disabled)
        .windowLevel(.floating)
        .windowBackgroundDragBehavior(.disabled)
        .defaultWindowPlacement { content, context in
            let displayBounds = context.defaultDisplay.visibleRect
            let proposal = ProposedViewSize(
                width: displayBounds.width, height: displayBounds.height)
            let contentSize = content.sizeThatFits(proposal)
            let rawX = UnitPoint.topTrailing.x - 0.05 * (contentSize.width / displayBounds.width)
            let x = min(max(rawX, 0), 1)
            let rawY = UnitPoint.topTrailing.y + 0.2 * (contentSize.height / displayBounds.height)
            let y = min(max(rawY, 0), 1)
            return WindowPlacement(.init(x: x,
                                         y: y))
        }
    }
}
