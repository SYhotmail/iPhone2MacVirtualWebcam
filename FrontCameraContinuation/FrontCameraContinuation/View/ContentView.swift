//
//  ContentView.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//

import SwiftUI

struct ContentView: View {
    let manager = StreamManager()
    @State var isStreaming = false
    @State private var host = "192.168.1.10"
    @State private var port = "9999"
    @State private var streamSize: StreamSize = .full

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            TextField("Mac IP address", text: $host)
                .textContentType(.URL)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("Port", text: $port)
                .keyboardType(.numberPad)

            Picker("Stream size", selection: $streamSize) {
                ForEach(manager.supportedCameraSessionPresets()) { size in
                    Text(size.title).tag(size)
                }
            }
            .pickerStyle(.menu)
            .disabled(isStreaming)

            Button(isStreaming ? "Stop Streaming" : "Start Streaming") {
                if isStreaming {
                    manager.stopStreaming()
                    isStreaming = false
                } else {
                    manager.startStreaming(
                        host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                        port: UInt16(port) ?? 9999,
                        streamSize: streamSize
                    )
                    isStreaming = true
                }
            }
            Spacer()
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
