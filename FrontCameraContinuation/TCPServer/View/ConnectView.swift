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
    let videoView = VideoView()
    
    @State var isRunning = false
    @State var listenerStatus: String = ""
    @State var connectionStatus: String = ""
    
    var body: some View {
        VStack(spacing: 12) {
            Button(isRunning ? "Stop" : "Start") {
                if isRunning {
                    manager.stop()
                    isRunning = false
                } else {
                    manager.start()
                    isRunning = true
                }
            }
            VideoViewRepresentable(videoView: videoView)
                .onAppear {
                    manager.decoder.displayLayer = videoView.displayLayer
                }
            HStack {
                Text("Listener: \(listenerStatus)")
                Spacer()
                Text("Connection: \(connectionStatus)")
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .padding(.bottom, 6)
        }
        .onReceive(manager.listenerStatusPublisher, perform: { value in
            self.listenerStatus = value
        })
        .onReceive(manager.connectionStateLastPublisher, perform: { value in
            self.connectionStatus = value
        })
        .padding()
        .frame(minWidth: 900, minHeight: 560)
    }
}

#Preview {
    ConnectView()
}
