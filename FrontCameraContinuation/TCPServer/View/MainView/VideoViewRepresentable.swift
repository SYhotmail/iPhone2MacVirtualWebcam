//
//  VideoViewRepresentable.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//


import SwiftUI
import Combine
import CoreMedia
internal import AVFoundation

struct VideoViewRepresentable: NSViewRepresentable {
    let frameProvider: any PreviewDecodedFrameProvidable
    
    private func defineVideoView(_ nsView: VideoView, context: Context) {
        let coordinator = context.coordinator
        coordinator.bind(frameProvider: frameProvider, renderer: nsView.sampleBufferRenderer)
    }
    
    func makeNSView(context: Context) -> VideoView {
        let view = VideoView(frame: .zero)
        defineVideoView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: VideoView, context: Context) {
        defineVideoView(nsView, context: context)
    }
    
    static func dismantleNSView(_ nsView: VideoView, coordinator: Coordinator) {
        coordinator.cancellable = nil
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    final class Coordinator: NSObject {
        var cancellable: AnyCancellable?
        
        func bind(frameProvider: PreviewDecodedFrameProvidable, renderer: AVSampleBufferVideoRenderer?) {
            guard let renderer else {
                return
            }
            cancellable = frameProvider.decodedFrameSubject().sink { [weak renderer] buffer in
                renderer?.enqueue(buffer)
            }
        }
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

