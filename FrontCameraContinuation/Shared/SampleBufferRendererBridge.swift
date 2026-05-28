//
//  SampleBufferRendererBridge.swift
//  FrontCameraContinuation
//
//  Created by OpenAI Codex on 27/05/2026.
//

import Dispatch
@preconcurrency import AVFoundation
import Combine

final class SampleBufferRendererBridge {
    var cancellable: AnyCancellable?
    let renderQueue: DispatchQueue
    
    init(queueLabel: String) {
        self.renderQueue = .init(label: queueLabel)
    }

    func bind(frameProvider: any PreviewDecodedFrameProvidable,
              renderer: AVSampleBufferVideoRenderer?) {
        cancellable = renderer.flatMap { Self.makeBinding(frameProvider: frameProvider,
                                                          renderer: $0,
                                                          renderQueue: renderQueue) }
    }

    nonisolated private static func makeBinding(frameProvider: any PreviewDecodedFrameProvidable,
                                                renderer: AVSampleBufferVideoRenderer,
                                                renderQueue: DispatchQueue) -> AnyCancellable {
        return frameProvider.decodedFrameSubject()
            .receive(on: renderQueue)
            .sink { [weak renderer] sampleBuffer in
                guard let renderer, renderer.isReadyForMoreMediaData else {
                    return
                }
                renderer.enqueue(sampleBuffer)
            }
    }
    
    func unbind() {
        cancellable = nil
    }
}

open class SampleBufferRendererCoodinator: NSObject {
    let bridge: SampleBufferRendererBridge
    
    init(queueLabel: String) {
        bridge = .init(queueLabel: queueLabel)
        super.init()
    }
    
    func unbind() {
        bridge.unbind()
    }
    
    func bind(frameProvider: any PreviewDecodedFrameProvidable,
              renderer: AVSampleBufferVideoRenderer?) {
        bridge.bind(frameProvider: frameProvider,
                    renderer: renderer)
    }
}
