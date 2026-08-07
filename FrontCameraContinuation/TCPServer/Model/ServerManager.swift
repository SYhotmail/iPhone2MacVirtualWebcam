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
    private let streamServer: FrameStreamServer
    private let sinkClient = VirtualCameraSinkClient()
    private let frameConverter = VirtualCameraSampleBufferConverter()
    private let blurProcessor = BackgroundBlurMetalRenderer()
    private var decodedFrameCancellable: Task<Void,Never>?
    private var _sharedFrameProvider: AnyPublisher<CMSampleBuffer, Never>!
    let decoder = H264Decoder()
    
    let lock = Mutex(())
    private let videoEffectLock = Mutex<VideoEffect?>(nil)

    init(tlsConfiguration: TLSConfiguration = .default) throws {
        let parameters = try tlsConfiguration.makeServerParameters()
        self.streamServer = FrameStreamServer { port in
            return try NWListener(using: parameters, on: port)
        }
    }
    
    nonisolated
    func frameProvider() -> AnyPublisher<CMSampleBuffer, Never> {
        decoder.publisher
            .map { $0.value }
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .compactMap { [weak self] sampleBuffer -> CMSampleBuffer? in
                guard let self else {
                    return nil
                }

                let effect = self.videoEffect
                let inputSampleBuffer = self.blurProcessor.process(sampleBuffer, effect: effect) ?? sampleBuffer
                return self.frameConverter.makeSampleBuffer(from: inputSampleBuffer)
            }
            .share()
            .eraseToAnyPublisher()
    }

    private func setSharedFrameProvider() -> AnyPublisher<CMSampleBuffer, Never> {
        if let value = _sharedFrameProvider {
            return value
        }
        
        let sharedFrameProvider = frameProvider()
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
        decodedFrameCancellable = Task {
            await bindStreamServerCore()
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
            self?.resetDecoder()
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
    
    private func unbindCore() {
        decodedFrameCancellable?.cancel()
        Task {
            await streamServer.setFrameHandler(nil)
            await streamServer.setStreamUnavailableHandler(nil)
        }
    }
}

extension ServerManager: PreviewDecodedFrameProvidable {
    nonisolated func decodedFrameSubject() -> AnyPublisher<CMSampleBuffer, Never> {
        frameProvider()
    }
}
