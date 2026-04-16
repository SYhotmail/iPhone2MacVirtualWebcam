//
//  ContentView.swift
//  TCPServer
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//

import SwiftUI
import Combine

struct ConnectView: View {
    let manager = ServerManager()
    @State var isRunning = false
    @State var listenerStatus: String = ""
    @State var connectionStatus: String = ""
    
    var body: some View {
        VStack {
            Button(isRunning ? "Stop" : "Start") {
                if isRunning {
                    manager.stop()
                } else {
                    manager.start()
                }
            }
            Spacer()
            HStack {
                Text("Listener: \(listenerStatus)")
                Spacer()
                Text("Connection: \(connectionStatus)")
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .padding(.bottom, 6)
        }
        .onReceive(manager.connectedPublisher, perform: { value in
            self.isRunning = value
        })
        .onReceive(manager.listenerStatusPublisher, perform: { value in
            self.listenerStatus = value
        })
        .onReceive(manager.connectionStateLastPublisher, perform: { value in
            self.connectionStatus = value
        })
        .padding()
    }
}

#Preview {
    ConnectView()
}
