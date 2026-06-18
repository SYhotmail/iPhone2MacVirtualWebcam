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
    private var decodedFrameCancellable: AnyCancellable?
    private var _sharedFrameProvider: AnyPublisher<CMSampleBuffer, Never>!
    let decoder = H264Decoder()
    
    let lock = Mutex(())
    private let videoEffectLock = Mutex(VideoEffect.none)

    init(tlsConfiguration: TLSConfiguration = .default) {
        self.streamServer = FrameStreamServer { port in
            let parameters = tlsConfiguration.makeParameters()
            return try NWListener(using: parameters, on: port)
        }
    }
    
    
    private func setSharedFrameProvider() -> AnyPublisher<CMSampleBuffer, Never> {
        if let value = _sharedFrameProvider {
            return value
        }
        
        let _sharedFrameProvider = decoder.publisher
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .map { $0.value }
            .compactMap { [weak self] sampleBuffer -> CMSampleBuffer? in
                guard let self else {
                    return nil
                }

                let effect = self.videoEffectLock.withLock { $0 }
                let inputSampleBuffer = self.blurProcessor.process(sampleBuffer, effect: effect) ?? sampleBuffer
                return self.frameConverter.makeSampleBuffer(from: inputSampleBuffer)
            }
            .share()
            .eraseToAnyPublisher()
        self._sharedFrameProvider = _sharedFrameProvider
        return _sharedFrameProvider
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

    func setVideoEffect(_ effect: VideoEffect) {
        videoEffectLock.withLock { value in
            value = effect
        }
    }

    func setBackgroundImage(_ image: NSImage?) {
        blurProcessor.setBackgroundImage(image)
    }
    
    private func bindCore(port: UInt16) {
        decodedFrameCancellable = sharedFrameProvider
            .sink { [weak self] sampleBuffer in
                self?.sinkClient.enqueue(sampleBuffer)
            }

        Task { [weak self] in
            guard let self else {
                return
            }

            await streamServer.setFrameHandler { [weak self] data in
                self?.decoder.scheduleToDecode(data)
            }

            await streamServer.setStreamUnavailableHandler { [weak self] in
                self?.decoder.scheduleToReset()
            }
        }
    }
    
    func start(port: UInt16 = 9999) {
        lock.withLock { _ in
            bindCore(port: port)
        }
        sinkClient.start()
        Task {
            try? await streamServer.start(on: port)
        }
    }
    
    private func resetDecoder() {
        decoder.scheduleToReset()
    }
    
    func stop() {
        lock.withLock { _ in
            unbindCore()
        }
        
        sinkClient.stop()
        resetDecoder()
        Task {
            await streamServer.stop()
        }
    }
    
    private func unbindCore() {
        decodedFrameCancellable = nil
        Task {
            await streamServer.setFrameHandler(nil)
            await streamServer.setStreamUnavailableHandler(nil)
        }
    }
}

extension ServerManager: PreviewDecodedFrameProvidable {
    nonisolated func decodedFrameSubject() -> AnyPublisher<CMSampleBuffer, Never> {
        sharedFrameProvider
    }
}
