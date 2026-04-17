//
//  ContentView.swift
//  TCPServer
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//

import SwiftUI
import Combine
internal import AVFoundation

struct ConnectView: View {
    let manager = ServerManager()
    
    @State var isRunning = false
    @State var listenerStatus: String = ""
    @State var connectionStatus: String = ""
    // @State var sampleBuffer: CMSampleBuffer?
    
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
            VideoViewRepresentable(decoder: manager.decoder)
                /*.onReceive(manager.decoder.decodedFramePublisher.receive(on: DispatchQueue.main)) { buffer in
                    self.sampleBuffer = buffer
                }*/
            
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
