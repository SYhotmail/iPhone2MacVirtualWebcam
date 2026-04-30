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

protocol PreviewDecodedFrameProvidable {
    func decodedFrameSubject() -> AnyPublisher<CMSampleBuffer, Never>
}

final class ServerManager {
    private let server = TCPServer()
    private let sinkClient = VirtualCameraSinkClient()
    private let frameConverter = VirtualCameraSampleBufferConverter()
    private var decodedFrameCancellable: AnyCancellable?
    let decoder = H264Decoder()
    
    private lazy var sharedFrameProvider: AnyPublisher<CMSampleBuffer, Never>! = {
        decoder.decodedFramePublisher
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .eraseToAnyPublisher()
            .compactMap { [weak self] sampleBuffer in
                self?.frameConverter.makeSampleBuffer(from: sampleBuffer)
            }
            .share()
            .eraseToAnyPublisher()
    }()
    
    var listenerStatusPublisher: AnyPublisher<String, Never> {
        server.listenerState.map(\.debugDescription).receive(on: RunLoop.main).eraseToAnyPublisher()
    }
    
    var connectionStateLastPublisher: AnyPublisher<String, Never> {
        server.connectionStates.map { publisher in publisher.map(\.debugDescription).receive(on: RunLoop.main).eraseToAnyPublisher() }.last!
    }
    
    var connectedPublisher: AnyPublisher<Bool, Never> {
        server.listenerState.combineLatest(server.connectionStates.last!) // TODO: resolve exclamation
            .map { $0 == .ready && $1 == .ready }
            .removeDuplicates().receive(on: RunLoop.main).eraseToAnyPublisher()
    }
    
    func start(port: UInt16 = 9999) {
        sinkClient.start()

        decodedFrameCancellable = decodedFrameSubject()
            .sink { [weak self] sampleBuffer in
                self?.sinkClient.enqueue(sampleBuffer)
            }

        server.onFrame = { [weak self] data in
            self?.decoder.decode(data)
        }

        server.onStreamUnavailable = { [weak self] in
            self?.resetDecoder()
        }
        
        try? server.start(port: port)
    }
    
    private func resetDecoder() {
        decoder.reset()
    }
    
    func stop() {
        server.onFrame = nil
        server.onStreamUnavailable = nil
        decodedFrameCancellable = nil
        sinkClient.stop()
        resetDecoder()
        server.stop()
    }
}

extension ServerManager: PreviewDecodedFrameProvidable {
    func decodedFrameSubject() -> AnyPublisher<CMSampleBuffer, Never> {
        sharedFrameProvider
    }
}
