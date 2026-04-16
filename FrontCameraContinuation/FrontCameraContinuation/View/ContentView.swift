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
    var body: some View {
        VStack {
            Spacer()
            Button(isStreaming ? "Stop Streaming" : "Start Streaming") {
                if isStreaming {
                    manager.stopStreaming()
                } else {
                    manager.startStreaming()
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
