//
//  ServerManager.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 30/04/2026.
//

import Foundation
import Combine
import CoreMedia
import Network
import Synchronization

protocol PreviewDecodedFrameProvidable {
   nonisolated func decodedFrameSubject() -> AnyPublisher<CMSampleBuffer, Never>
}

nonisolated
final class ServerManager: @unchecked Sendable {
    private let server = TCPServer()
    private let sinkClient = VirtualCameraSinkClient()
    private let frameConverter = VirtualCameraSampleBufferConverter()
    private nonisolated(unsafe) var decodedFrameCancellable: AnyCancellable?
    private nonisolated(unsafe) var _sharedFrameProvider: AnyPublisher<CMSampleBuffer, Never>!
    let decoder = H264Decoder()
    
    let lock = Mutex(())
    
    
    private func setSharedFrameProvider() -> AnyPublisher<CMSampleBuffer, Never> {
        if let value = _sharedFrameProvider {
            return value
        }
        
        let _sharedFrameProvider = decoder.decodedFramePublisher
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .eraseToAnyPublisher()
            .compactMap { [weak self] sampleBuffer in
                self?.frameConverter.makeSampleBuffer(from: sampleBuffer)
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
        server.listenerState
            .map(\.debugDescription)
            .onMainAnyPublisher()
    }
    
    var connectionStateLastPublisher: AnyPublisher<String, Never> {
        server.connectionStates
            .map(\.debugDescription)
            .onMainAnyPublisher()
    }
    
    var connectedPublisher: AnyPublisher<Bool, Never> {
        server.listenerState.combineLatest(server.connectionStates)
            .map { $0 == .ready && $1 == .ready }
            .removeDuplicates()
            .onMainAnyPublisher()
    }
    
    private func bindCore(port: UInt16) {
        decodedFrameCancellable = sharedFrameProvider
            .sink { [weak self] sampleBuffer in
                self?.sinkClient.enqueue(sampleBuffer)
            }

        server.onFrame = { [weak self] data in
            self?.decoder.decode(data)
        }

        server.onStreamUnavailable = { [weak self] in
            self?.resetDecoder()
        }
    }
    
    func start(port: UInt16 = 9999) {
        lock.withLock { _ in
            bindCore(port: port)
        }
        sinkClient.start()
        try? server.start(port: port)
    }
    
    private func resetDecoder() {
        decoder.reset()
    }
    
    func stop() {
        lock.withLock { _ in
            unbindCore()
        }
        
        sinkClient.stop()
        resetDecoder()
        server.stop()
    }
    
    private func unbindCore() {
        server.onFrame = nil
        server.onStreamUnavailable = nil
        decodedFrameCancellable = nil
    }
}

extension ServerManager: PreviewDecodedFrameProvidable {
    nonisolated func decodedFrameSubject() -> AnyPublisher<CMSampleBuffer, Never> {
        sharedFrameProvider
    }
}
