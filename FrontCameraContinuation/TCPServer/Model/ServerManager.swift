//
//  ServerManager.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 30/04/2026.
//

import AppKit
import Combine
import CoreMedia
import Foundation
import H264
import Network
import Synchronization
import Transport

nonisolated
final class ServerManager: @unchecked Sendable {
    private struct FrameProcessingState {
        var pendingSampleBuffer: CMSampleBuffer?
        var isProcessing = false
    }

    private let streamServer: FrameStreamServer
    private let sinkClient = VirtualCameraSinkClient()
    private let frameConverter = VirtualCameraSampleBufferConverter()
    private let blurProcessor = BackgroundBlurMetalRenderer()
    private var decodedFrameCancellable: Task<Void,Never>?
    private var decodedFrameInputCancellable: AnyCancellable?
    private var _sharedFrameProvider: AnyPublisher<CMSampleBuffer, Never>!
    private let processedFramePublisher = PassthroughSubject<CMSampleBuffer, Never>()
    let decoder = H264Decoder()
    let queue = DispatchQueue(label: "videoeffect.queue")
    private let frameProcessingStateQueue = DispatchQueue(label: "server.frame-processing.state")
    private var frameProcessingState = FrameProcessingState()
    let lock = Mutex(())
    private let videoEffectLock = Mutex<VideoEffect?>(nil)

    init(tlsConfiguration: TLSConfiguration = .default) throws {
        let parameters = try tlsConfiguration.makeServerParameters()
        self.streamServer = FrameStreamServer { port in
            return try NWListener(using: parameters, on: port)
        }
    }
    
    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        let effect = videoEffect
        let inputSampleBuffer = blurProcessor.process(sampleBuffer, effect: effect) ?? sampleBuffer
        return frameConverter.makeSampleBuffer(from: inputSampleBuffer)
    }
    
    nonisolated
    func frameProvider() -> AnyPublisher<CMSampleBuffer, Never> {
        processedFramePublisher
            .eraseToAnyPublisher()
    }

    private func setSharedFrameProvider() -> AnyPublisher<CMSampleBuffer, Never> {
        if let value = _sharedFrameProvider {
            return value
        }
        
        let sharedFrameProvider = frameProvider().buffer(size: 1, prefetch: .byRequest, whenFull: .dropOldest).eraseToAnyPublisher()
        self._sharedFrameProvider = sharedFrameProvider
        return sharedFrameProvider
    }
    
    private var sharedFrameProvider: AnyPublisher<CMSampleBuffer, Never> {
        lock.withLockIfAvailable { _ in
            setSharedFrameProvider()
        } ?? setSharedFrameProvider()
    }
    
    var listenerStatusPublisher: AnyPublisher<String, Never> {
        streamServer.state.listenerState
            .map(\.debugDescription)
            .onMainAnyPublisher()
    }
    
    var connectionStateLastPublisher: AnyPublisher<String, Never> {
        streamServer.state.connectionState
            .map(\.debugDescription)
            .onMainAnyPublisher()
    }
    
    var connectedPublisher: AnyPublisher<Bool, Never> {
        streamServer.state.listenerState.combineLatest(streamServer.state.connectionState)
            .map { $0 == .ready && $1 == .ready }
            .removeDuplicates()
            .onMainAnyPublisher()
    }

    func setVideoEffect(_ effect: VideoEffect?) {
        videoEffectLock.withLock { value in
            value = effect
        }
    }
    
    var videoEffect: VideoEffect? {
        videoEffectLock.withLock { $0 }
    }

    func setBackgroundImage(_ image: NSImage?) {
        blurProcessor.setBackgroundImage(image)
    }
    
    private func bindCore(port: UInt16) {
        Task {
            await bindStreamServerCore()
        }

        bindDecodedFrameProcessing()
        
        decodedFrameCancellable = Task {
            guard !Task.isCancelled else {
                return
            }
            
            let stream = sharedFrameProvider
                .map { H264Decoder.SendableSampleBuffer(value: $0) }
                .values
            
            for await bufferWrapper in stream {
                await sinkClient.enqueue(bufferWrapper)
                
                guard !Task.isCancelled else {
                    return
                }
            }
        }
    }
    
    private func bindStreamServerCore() async {
        await streamServer.setFrameHandler { [weak self] data in
            self?.decoder.scheduleToDecode(data)
        }

        await streamServer.setStreamUnavailableHandler { [weak self] in
            self?.handleStreamUnavailable()
        }
    }
    
    func start(port: UInt16 = 9999) {
        lock.withLock { _ in
            bindCore(port: port)
        }
        Task {
            await startCore(port: port)
        }
    }
    
    private func startCore(port: UInt16) async {
        await sinkClient.start()
        try? await streamServer.start(on: port)
    }
    
    private func stopCore() async {
        await sinkClient.stop()
        await streamServer.stop()
    }
    
    private func bindDecodedFrameProcessing() {
        decodedFrameInputCancellable = decoder.publisher
            .sink { [weak self] sampleBuffer in
                self?.enqueueLatestDecodedFrame(sampleBuffer.value)
            }
    }

    private func enqueueLatestDecodedFrame(_ sampleBuffer: CMSampleBuffer) {
        var shouldStartProcessing = false
        frameProcessingStateQueue.sync {
            frameProcessingState.pendingSampleBuffer = sampleBuffer
            guard !frameProcessingState.isProcessing else {
                shouldStartProcessing = false
                return
            }
            frameProcessingState.isProcessing = true
            shouldStartProcessing = true
        }

        guard shouldStartProcessing else {
            return
        }

        queue.async { [weak self] in
            self?.drainLatestDecodedFrames()
        }
    }

    private func drainLatestDecodedFrames() {
        while let pendingSampleBuffer = takePendingDecodedFrame() {
            guard let processedSampleBuffer = processSampleBuffer(pendingSampleBuffer) else {
                continue
            }
            processedFramePublisher.send(processedSampleBuffer)
        }
    }

    private func takePendingDecodedFrame() -> CMSampleBuffer? {
        frameProcessingStateQueue.sync {
            guard let pendingSampleBuffer = frameProcessingState.pendingSampleBuffer else {
                frameProcessingState.isProcessing = false
                return nil
            }
            frameProcessingState.pendingSampleBuffer = nil
            return pendingSampleBuffer
        }
    }

    private func clearPendingDecodedFrames() {
        frameProcessingStateQueue.sync {
            frameProcessingState.pendingSampleBuffer = nil
        }
    }

    private func handleStreamUnavailable() {
        clearPendingDecodedFrames()
        resetDecoder()
    }

    private func resetDecoder() {
        decoder.scheduleToReset()
    }
    
    func stop() {
        lock.withLock { _ in
            unbindCore()
        }
        
        Task {
            await decoder.reset()
            await stopCore()
        }
    }
    
    private func unbindStreamServerCore() async {
        await streamServer.setFrameHandler(nil)
        await streamServer.setStreamUnavailableHandler(nil)
    }
    
    private func unbindCore() {
        decodedFrameCancellable?.cancel()
        decodedFrameInputCancellable = nil
        clearPendingDecodedFrames()
        Task {
            await unbindStreamServerCore()
        }
    }
}

extension ServerManager: PreviewDecodedFrameProvidable {
    nonisolated func decodedFrameSubject() -> AnyPublisher<CMSampleBuffer, Never> {
        sharedFrameProvider
    }
}
