//
//  VideoViewRepresentable.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//

import AVFoundation
import Combine
import SwiftUI
import UIKit

struct CameraPreview: PlatformNativeViewRepresentable {
    let frameProvider: any PreviewDecodedFrameProvidable
    typealias UIViewType = VideoView
    private func defineVideoView(_ nsView: PlatformViewType, context: Context) {
        let coordinator = context.coordinator
        coordinator.bind(frameProvider: frameProvider, renderer: nsView.sampleBufferRenderer)
        coordinator.defineView(nsView)
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
        coordinator.cancellable = nil
        coordinator.undefineView(view)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    final class Coordinator: NSObject {
        @Cancelling
        var cancellable: AnyCancellable?
        
        lazy var doubleTapGesture: UITapGestureRecognizer! = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(sender: )))
            tap.numberOfTapsRequired = 2
            return tap
        }()
        
        func defineView(_ uiView: VideoView) {
            guard uiView.gestureRecognizers?.firstIndex(where: { $0 === doubleTapGesture } ) == nil else { return }
            uiView.isUserInteractionEnabled = true
            uiView.addGestureRecognizer(doubleTapGesture)
        }
        
        func undefineView(_ uiView: VideoView) {
            guard let index = uiView.gestureRecognizers?.firstIndex(where: { $0 === doubleTapGesture } ) else {
                return
            }
            uiView.gestureRecognizers?.remove(at: index)
        }
        
        @objc private func handleDoubleTap(sender: UITapGestureRecognizer) {
            guard let view = sender.view as? VideoView, let displayLayer = view.displayLayer else {
                return
            }
            
            switch displayLayer.videoGravity {
            case .resizeAspect:
                displayLayer.videoGravity = .resizeAspectFill
            case .resizeAspectFill:
                displayLayer.videoGravity = .resizeAspect
            default:
                break
            }
        }
        
        func bind(frameProvider: PreviewDecodedFrameProvidable, renderer: AVSampleBufferVideoRenderer?) {
            guard let renderer else {
                cancellable = nil
                return
            }
            cancellable = frameProvider.decodedFrameSubject().onMainAnyPublisher().sink { [weak renderer] buffer in
                renderer?.enqueue(buffer)
            }
        }
    }
}

// MARK: - VideoView
final class VideoView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }
    
    var displayLayer: AVSampleBufferDisplayLayer? {
        layer as? AVSampleBufferDisplayLayer
    }
    
    var sampleBufferRenderer: AVSampleBufferVideoRenderer? {
        displayLayer?.sampleBufferRenderer
    }
}
