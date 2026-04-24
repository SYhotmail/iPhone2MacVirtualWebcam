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
        } /*{
            Window("Quick Setup", id: "quick-setup") {
                QuickSetupView()
            }
        }*/

    }
}
