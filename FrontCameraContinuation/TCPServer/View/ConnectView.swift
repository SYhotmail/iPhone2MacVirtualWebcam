//
//  ContentView.swift
//  TCPServer
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//

import SwiftUI
import Combine

/*
 let videoView = VideoView()
     let decoder = H264Decoder()

     var body: some View {
         VideoViewRepresentable(videoView: videoView)
             .onAppear {
                 decoder.displayLayer = videoView.displayLayer
             }
     }
 */

struct ConnectView: View {
    let manager = ServerManager()
    let videoView = VideoView()
    
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
            
            VideoViewRepresentable(videoView: videoView)
                .onAppear {
                    manager.decoder.displayLayer = videoView.displayLayer
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
