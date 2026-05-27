//
//  VideoViewRepresentable.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//

import SwiftUI
import CoreMedia
@preconcurrency import AVFoundation

struct VideoPreview: PlatformNativeViewRepresentable {
    typealias NSViewType = VideoView
    typealias Coordinator = SampleBufferRendererCoodinator
    
    let frameProvider: any PreviewDecodedFrameProvidable
    
    private func defineVideoView(_ nsView: VideoView, context: Context) {
        let coordinator = context.coordinator
        coordinator.bind(frameProvider: frameProvider, renderer: nsView.sampleBufferRenderer)
    }
    
    func makePlatformView(context: Context) -> PlatformViewType {
        let view = VideoView(frame: .zero)
        defineVideoView(view, context: context)
        return view
    }

    func updatePlatformView(_ view: PlatformViewType, context: Context) {
        defineVideoView(view, context: context)
    }
    
    static func dismantleView(_ view: PlatformViewType, coordinator: Coordinator) {
        coordinator.unbind()
    }
    
    func makeCoordinator() -> Coordinator {
        .init(queueLabel: "by.sy.TCPServer.VideoPreview.render")
    }
    
}

// MARK: - VideoView
final class VideoView: NSView {
    private var displayLayer: AVSampleBufferDisplayLayer? {
        layer as? AVSampleBufferDisplayLayer
    }
    
    var sampleBufferRenderer: AVSampleBufferVideoRenderer? {
        displayLayer?.sampleBufferRenderer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
    }
    
    override func makeBackingLayer() -> CALayer {
        AVSampleBufferDisplayLayer()
    }
    
    required init?(coder: NSCoder) {
        fatalError()
    }
}
