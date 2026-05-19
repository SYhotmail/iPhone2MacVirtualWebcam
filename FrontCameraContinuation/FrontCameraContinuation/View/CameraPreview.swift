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
    let pipController: CameraPIPManager
    let frameProvider: any PreviewDecodedFrameProvidable
    
    typealias UIViewType = VideoView
    
    private func defineVideoView(_ nsView: PlatformViewType, context: Context) {
        let coordinator = context.coordinator
        coordinator.bind(frameProvider: frameProvider, view: nsView)
    }
    
    func makePlatformView(context: Context) -> PlatformViewType {
        let view = VideoView(frame: .zero)
        
        defineVideoView(view, context: context)
        return view
    }

    func updatePlatformView(_ view: PlatformViewType, context: Context) {
        defineVideoView(view, context: context)
        context.coordinator.pipController = pipController
        pipController.attach(sourceView: view, frameProvider: frameProvider)
    }
    
    
    static func dismantleView(_ view: PlatformViewType, coordinator: Coordinator) {
        coordinator.undefineView(view)
        coordinator.pipController?.detach(sourceView: view)
        coordinator.pipController = nil
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    final class Coordinator: NSObject {
        @Cancelling
        var cancellable: AnyCancellable?
        
        var pipController: CameraPIPManager?
        
        lazy var doubleTapGesture: UITapGestureRecognizer! = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(sender: )))
            tap.numberOfTapsRequired = 2
            return tap
        }()
        
        private func addTapGesture(_ uiView: UIView) {
            guard uiView.gestureRecognizers?.firstIndex(where: { $0 === doubleTapGesture } ) == nil else { return }
            uiView.isUserInteractionEnabled = true
            uiView.addGestureRecognizer(doubleTapGesture)
        }
        
        private func removeTapGesture(_ uiView: UIView) {
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
        
        private func resetCancellable() {
            cancellable = nil
        }
        
        func undefineView(_ view: UIView) {
            resetCancellable()
            removeTapGesture(view)
        }
        
        func bind(frameProvider: PreviewDecodedFrameProvidable, view: VideoView) {
            bind(frameProvider: frameProvider, renderer: view.sampleBufferRenderer)
            addTapGesture(view)
        }
        
        private func bind(frameProvider: PreviewDecodedFrameProvidable, renderer: AVSampleBufferVideoRenderer?) {
            guard let renderer else {
                resetCancellable()
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
