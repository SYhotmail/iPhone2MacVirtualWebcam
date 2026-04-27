//
//  Cam2MacApp.swift
//  Cam2Mac
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//

import SwiftUI

@main
struct Cam2MacApp: App {
    static let quickSetupId = "quick-setup"
    var body: some Scene {
        WindowGroup {
            ConnectView()
        }
        .windowManagerRole(.principal)
        .defaultSize(width: 800, height: 640)
        .commands {
            QuickSetupCommands()
        }

        WindowGroup("Quick Setup", id: Self.quickSetupId) {
            QuickSetupView()
                .frame(minWidth: 400, maxWidth: 900, minHeight: 400)
        }
        .defaultSize(width: 500, height: 500)
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
