//
//  TCPServer.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//


import Network
import Foundation
import Combine
import VideoToolbox
import CoreMedia
import CoreVideo

final class ServerManager {
    private let server = TCPServer()
    private let sinkClient = VirtualCameraSinkClient()
    private let frameConverter = VirtualCameraSampleBufferConverter()
    private var decodedFrameCancellable: AnyCancellable?
    let decoder = H264Decoder()
    
    var listenerStatusPublisher: AnyPublisher<String, Never> {
        server.listenerState.map(\.debugDescription).receive(on: RunLoop.main).eraseToAnyPublisher()
    }
    
    var connectionStateLastPublisher: AnyPublisher<String, Never> {
        server.connectionStates.map { publisher in publisher.map(\.debugDescription).receive(on: RunLoop.main).eraseToAnyPublisher() }.last!
    }
    
    var connectedPublisher: AnyPublisher<Bool, Never> {
        server.listenerState.combineLatest(server.connectionStates.last!).map { $0 == .ready && $1 == .ready }.removeDuplicates().receive(on: RunLoop.main).eraseToAnyPublisher()
    }
    
    func start(port: UInt16 = 9999) {
        sinkClient.start()

        decodedFrameCancellable = decoder.decodedFramePublisher
            .share()
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .compactMap { [frameConverter] sampleBuffer in
                frameConverter.makeSampleBuffer(from: sampleBuffer)
            }
            .sink { [weak sinkClient] sampleBuffer in
                sinkClient?.enqueue(sampleBuffer)
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

protocol NetworkConnectionStateProvable {
    var error: NWError? { get }
    var isConnected: Bool { get }
}

extension NWConnection.State : NetworkConnectionStateProvable, @retroactive CustomDebugStringConvertible {
    var error: NWError? {
        switch self {
        case .failed(let error):
            return error
        case .waiting(let error):
            return error
        default:
            return nil
        }
    }
    
    var isConnected: Bool {
        if case .ready = self {
            return true
        }
        
        return false
    }
    
    public var debugDescription: String {
        switch self {
        case .ready:
            return "Ready"
        case .cancelled:
            return "Cancelled"
        case .failed(let error):
            return "Failed: \(error)"
        case .waiting(let error):
            return "Waiting: \(error)"
        case .setup:
            return "Setup"
        case .preparing:
            return "Preparing"
        @unknown default:
            return "Unknown"
        }
    }
}

extension NWListener.State: NetworkConnectionStateProvable, @retroactive CustomDebugStringConvertible {
    var error: NWError? {
        switch self {
        case .failed(let error):
            return error
        case .waiting(let error):
            return error
        default:
            return nil
        }
    }
    
    var isConnected: Bool {
        if case .ready = self {
            return true
        }
        
        return false
    }
    
    public var debugDescription: String {
        switch self {
        case .ready:
            return "Ready"
        case .cancelled:
            return "Cancelled"
        case .failed(let error):
            return "Failed: \(error)"
        case .waiting(let error):
            return "Waiting: \(error)"
        case .setup:
            return "Setup"
        @unknown default:
            return "Unknown"
        }
    }
}

private final class TCPServer {

    var onFrame: ((Data) -> Void)?
    var onStreamUnavailable: (() -> Void)?
    
    private var listener: NWListener!
    
    private var connections = [NWConnection]()
    private var inactivityTimers = [ObjectIdentifier: DispatchWorkItem]()
    private let inactivityTimeout: TimeInterval = 2
    let connectionStates = [CurrentValueSubject<NWConnection.State, Never>].init(repeating: .init(.setup), count: 1)
    let listenerState = CurrentValueSubject<NWListener.State, Never>(.setup)
    
    let lock = NSRecursiveLock()
    
    func start(port: UInt16) throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        
        listener.newConnectionHandler = { [weak self] connection in
            connection.stateUpdateHandler = { state in
                debugPrint("Connection state \(state)")
                guard let self else { return }
                self.lock.lock()
                defer {
                    self.lock.unlock()
                }
                
                self.connectionStates.last!.value = connection.state
                
                switch state {
                    case .ready:
                        self.scheduleInactivityTimeout(for: connection)
                        self.receive(connection)

                    case .waiting(let error):
                        debugPrint("⏳ Connection waiting:", error)
                        self.close(connection, cancel: true)

                    case .failed(let error):
                        debugPrint("❌ Connection failed:", error)
                        self.close(connection, cancel: false)

                    case .cancelled:
                        debugPrint("🔌 Connection cancelled")
                        self.close(connection, cancel: false)
                    default:
                        break
                    }
            }
            
            guard let self else { return }
            self.lock.withLock {
                self.cancelConnections(force: true)
                self.connections.append(connection)
            }
            connection.start(queue: .global(qos: .userInitiated))
            //self.receive(connection)
        }
        
        listener.stateUpdateHandler = { [weak self] state in
            debugPrint("Listener State \(state)")
            self?.listenerState.value = state
        }

        self.listener = listener
        listener.start(queue: .global(qos: .userInitiated))
    }
    
    private func remove(_ connection: NWConnection) {
        cancelInactivityTimeout(for: connection)
        connection.stateUpdateHandler = nil
        connections.removeAll { $0 === connection }
    }
    
    func cancelConnections(force: Bool = false) {
        connections.forEach {
            cancelInactivityTimeout(for: $0)
            $0.stateUpdateHandler = nil
            if force {
                $0.forceCancel()
            } else {
                $0.cancel()
            }
        }
        connections.removeAll()
        connectionStates.last!.value = .cancelled
        onStreamUnavailable?()
        //connectionStates.removeAll()
    }
    
    func stop() {
        guard let listener else {
            return
        }
        listener.cancel()
        cancelConnections()
        listener.stateUpdateHandler = nil
        self.listener = nil
    }
    
    private func receive(_ connection: NWConnection) {
        readSize(connection)
    }

    private func readSize(_ connection: NWConnection) {
        debugPrint("📥 Waiting for frame size...")
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { sizeData, _, _, error in
            guard let sizeData, sizeData.count == 4 else {
                debugPrint("❌ Failed to read size:", error ?? "unknown")
                self.close(connection, cancel: true)
                return
            }

            let size = sizeData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            self.readFrame(connection, expectedSize: Int(size), buffer: Data())
        }
    }

    private func readFrame(_ connection: NWConnection, expectedSize: Int, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: expectedSize - buffer.count) {
            chunk, _, _, error in
            guard let chunk, !chunk.isEmpty else {
                debugPrint("❌ Failed to read frame:", error ?? "unknown")
                self.close(connection, cancel: true)
                return
            }
            
            debugPrint("📦 Receiving frame chunk:", chunk.count)
            var newBuffer = buffer
            newBuffer.append(chunk)

            if newBuffer.count < expectedSize {
                // keep reading
                self.readFrame(connection, expectedSize: expectedSize, buffer: newBuffer)
            } else {
                // ✅ full frame received
                self.scheduleInactivityTimeout(for: connection)
                self.onFrame?(newBuffer)

                // read next frame
                self.readSize(connection)
            }
        }
    }

    private func scheduleInactivityTimeout(for connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        let workItem = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.lock.withLock {
                guard self.connections.contains(where: { $0 === connection }) else { return }
            }

            debugPrint("⏱️ No video frames received; closing stale connection")
            self.close(connection, cancel: true)
        }

        lock.withLock {
            inactivityTimers[identifier]?.cancel()
            inactivityTimers[identifier] = workItem
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + inactivityTimeout, execute: workItem)
    }

    private func cancelInactivityTimeout(for connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        inactivityTimers[identifier]?.cancel()
        inactivityTimers.removeValue(forKey: identifier)
    }

    private func close(_ connection: NWConnection, cancel: Bool) {
        if cancel {
            connection.cancel()
        }
        lock.withLock {
            remove(connection)
            connectionStates.last!.value = .cancelled
        }
        onStreamUnavailable?()
    }
}
