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

nonisolated
final class TCPServer: @unchecked Sendable {
    var onFrame: ((Data) -> Void)?
    var onStreamUnavailable: (() -> Void)?
    
    private var listener: NWListener! {
        didSet {
            guard let oldValue, oldValue !== listener else {
                return
            }
            oldValue.cancel()
        }
    }
    
    private var connections = [NWConnection]()
    private var inactivityTimers = [ObjectIdentifier: DispatchWorkItem]()
    private let inactivityTimeout: TimeInterval = 2
    let connectionStates = CurrentValueSubject<NWConnection.State, Never>(.setup)
    let listenerState = CurrentValueSubject<NWListener.State, Never>(.setup)
    
    let connectionQueue = DispatchQueue.global(qos: .userInitiated)
    
    let lock = NSRecursiveLock()
    
    func start(port: UInt16) throws {
        guard let portValue = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "tcp-server", code: .min, userInfo: [NSLocalizedFailureErrorKey: "Invalid port \(port)"])
        }
        
        let listener = try NWListener(using: .tcp, on: portValue)
        // listener.newConnectionLimit = 1 // TODO: why not one?
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        
        listener.stateUpdateHandler = { [weak self] state in
            debugPrint("Listener State \(state)")
            self?.listenerState.value = state
        }
        
        self.lock.lock()
        defer {
            self.lock.unlock()
        }

        self.listener = listener
        listener.start(queue: connectionQueue)
    }
    
    private func handleConnectionStateUpdate(_ state: NWConnection.State, for connection: NWConnection) {
        debugPrint("Connection state \(state)")
        self.lock.lock()
        defer {
            self.lock.unlock()
        }
        
        connectionStates.value = connection.state
        var cancel: Bool?
        switch state {
            case .ready:
                scheduleInactivityTimeout(for: connection)
                receive(connection)
            case .waiting(let error):
                debugPrint("⏳ Connection waiting:", error)
                cancel = true
            case .failed(let error):
                debugPrint("❌ Connection failed:", error)
                cancel = false
            case .cancelled:
                debugPrint("🔌 Connection cancelled")
                cancel = false
            default:
                break
        }
        
        if let cancel {
            close(connection, cancel: cancel)
        }
    }
    
    private func bindToConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak connection, weak self] state in
            guard let self, let connection else { return }
            self.handleConnectionStateUpdate(state, for: connection)
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        lock.withLock {
            cancelConnections(force: true)
            connections.append(connection)
        }
        bindToConnection(connection)
        connection.start(queue: connectionQueue)
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
        connectionStates.value = .cancelled
        onStreamUnavailable?()
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
    
    private func cancelAndClose(_ connection: NWConnection) {
        close(connection, cancel: true)
    }

    private func readSize(_ connection: NWConnection) {
        debugPrint("!!! readSize function start \(Date().timeIntervalSince1970)")
        let sizeCount = 4
        connection.receive(minimumIncompleteLength: sizeCount, maximumLength: sizeCount) { sizeData, _, _, error in
            debugPrint("!!! readSize function end \(Date().timeIntervalSince1970)")
            guard let sizeData, sizeData.count == sizeCount else {
                debugPrint("❌ Failed to read size:", error ?? "unknown")
                self.cancelAndClose(connection)
                return
            }

            let size = sizeData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            self.readFrame(connection, expectedSize: Int(size), buffer: Data())
        }
    }

    private func readFrame(_ connection: NWConnection, expectedSize: Int, buffer: Data) {
        debugPrint("!!! readFrame function start \(Date().timeIntervalSince1970)")
        connection.receive(minimumIncompleteLength: 1, maximumLength: expectedSize - buffer.count) {
            chunk, _, _, error in
            debugPrint("!!! readFrame function end \(Date().timeIntervalSince1970)")
            guard let chunk, !chunk.isEmpty else {
                debugPrint("❌ Failed to read frame:", error ?? "unknown")
                self.cancelAndClose(connection)
                return
            }

            var newBuffer = buffer
            newBuffer.append(chunk)

            if newBuffer.count < expectedSize {
                // keep reading
                self.readFrame(connection, expectedSize: expectedSize, buffer: newBuffer)
            } else {
                // ✅ full frame received
                self.scheduleInactivityTimeout(for: connection)
                debugPrint("!!! onFrame accumulated \(Date().timeIntervalSince1970)")
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
        connectionQueue.asyncAfter(deadline: .now() + inactivityTimeout, execute: workItem)
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
            connectionStates.value = .cancelled
        }
        onStreamUnavailable?()
    }
}
