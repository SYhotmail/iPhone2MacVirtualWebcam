//
//  TCPServerApp.swift
//  TCPServer
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//

import SwiftUI

@main
struct TCPServerApp: App {
    var body: some Scene {
        WindowGroup {
            ConnectView()
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            QuickSetupCommands()
        }

        WindowGroup("Quick Setup", id: "quick-setup") {
            QuickSetupView()
                .frame(minWidth: 400, maxWidth: 900, minHeight: 400)
        }.defaultSize(width: 500, height: 600)
    }
}
