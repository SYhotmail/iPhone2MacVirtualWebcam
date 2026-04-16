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
        server.onFrame = { [weak self] data in
            self?.decoder.decode(data)
        }
        
        try? server.start(port: port)
    }
    
    func stop() {
        server.onFrame = nil
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
    
    private var listener: NWListener!
    
    private var connections = [NWConnection]()
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
                        self.receive(connection)

                    case .failed(let error):
                        print("❌ Connection failed:", error)
                        self.remove(connection)

                    case .cancelled:
                        print("🔌 Connection cancelled")
                        self.remove(connection)
                    default:
                        break
                    }
            }
            
            guard let self else { return }
            self.lock.withLock {
                self.connections.append(connection)
            }
            connection.start(queue: .global())
            //self.receive(connection)
        }
        
        listener.newConnectionLimit = 1
        listener.stateUpdateHandler = { [weak self] state in
            debugPrint("Listener State \(state)")
            self?.listenerState.value = state
        }

        self.listener = listener
        listener.start(queue: .global())
    }
    
    private func remove(_ connection: NWConnection) {
        connection.stateUpdateHandler = nil
        connections.removeAll { $0 === connection }
    }
    
    func cancelConnections(force: Bool = false) {
        connections.forEach {
            $0.stateUpdateHandler = nil
            if force {
                $0.forceCancel()
            } else {
                $0.cancel()
            }
        }
        connections.removeAll()
        connectionStates.last!.value = .cancelled
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
        print("📥 Waiting for frame size...")
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { sizeData, _, _, error in
            guard let sizeData, sizeData.count == 4 else {
                print("❌ Failed to read size:", error ?? "unknown")
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
                print("❌ Failed to read frame:", error ?? "unknown")
                return
            }
            
            print("📦 Receiving frame chunk:", chunk.count)
            var newBuffer = buffer
            newBuffer.append(chunk)

            if newBuffer.count < expectedSize {
                // keep reading
                self.readFrame(connection, expectedSize: expectedSize, buffer: newBuffer)
            } else {
                // ✅ full frame received
                self.onFrame?(newBuffer)

                // read next frame
                self.readSize(connection)
            }
        }
    }
}
