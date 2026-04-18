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
    @StateObject private var installer = VirtualCameraInstaller()
    
    @State var isRunning = false
    @State var listenerStatus: String = ""
    @State var connectionStatus: String = ""
    // @State var sampleBuffer: CMSampleBuffer?
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button(isRunning ? "Stop" : "Start") {
                    if isRunning {
                        manager.stop()
                        isRunning = false
                    } else {
                        manager.start()
                        isRunning = true
                    }
                }
                Button("Install Virtual Camera") {
                    installer.activate()
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
            Text("Virtual Camera: \(installer.status)")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Move the built app to /Applications before installing the extension.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
