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
    let decoder: H264Decoder
    
    private func defineVideoView(_ nsView: VideoView, context: Context) {
        let coordinator = context.coordinator
        coordinator.nsView = nsView
        coordinator.bind(decoder: decoder)
    }
    
    func makeNSView(context: Context) -> VideoView {
        let view = VideoView()
        defineVideoView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: VideoView, context: Context) {
        defineVideoView(nsView, context: context)
    }
    
    static func dismantleNSView(_ nsView: VideoView, coordinator: Coordinator) {
        guard nsView === coordinator.nsView else {
            return
        }
        coordinator.nsView = nil
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject {
        weak var nsView: VideoView?
        
        private var cancellable: AnyCancellable?
        
        func bind(decoder: H264Decoder) {
            cancellable = decoder.decodedFramePublisher.share().receive(on: RunLoop.main).sink { [weak self] buffer in
                self?.nsView?.displayLayer.sampleBufferRenderer.enqueue(buffer)
            }
        }
        
    }
}
