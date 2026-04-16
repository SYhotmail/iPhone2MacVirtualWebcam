//
//  VideoViewRepresentable.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//


import SwiftUI

struct VideoViewRepresentable: NSViewRepresentable {
    let videoView: VideoView

    func makeNSView(context: Context) -> VideoView {
        videoView
    }

    func updateNSView(_ nsView: VideoView, context: Context) {}
}