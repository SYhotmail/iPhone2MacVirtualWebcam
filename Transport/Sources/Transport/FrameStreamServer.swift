import Combine
import Foundation
import Network

/// Shared observable server state for UI-facing consumers.
public final class FrameStreamServerState: @unchecked Sendable {
    public let connectionState = CurrentValueSubject<TransportConnectionState, Never>(.setup)
    public let listenerState = CurrentValueSubject<TransportListenerState, Never>(.setup)

    public init() {}
}

/// Receives packetized frame data from a single TCP client.
public actor FrameStreamServer {
    public nonisolated let state: FrameStreamServerState

    private var onFrame: (@Sendable (Data) -> Void)?
    private var onStreamUnavailable: (@Sendable () -> Void)?

    private var listener: (any TransportListener)! {
        didSet {
            guard let oldValue, oldValue !== listener else {
                return
            }
            oldValue.cancel()
        }
    }

    private var connections = [any TransportConnection]()
    private var inactivityTimers = [ObjectIdentifier: DispatchWorkItem]()
    private let inactivityTimeout: TimeInterval = 2
    private let connectionQueue = DispatchQueue.global(qos: .userInitiated)
    private let listenerFactory: NetworkListenerFactory

    public init() {
        self.init(listenerFactory: .live)
    }

    init(listenerFactory: NetworkListenerFactory) {
        self.state = FrameStreamServerState()
        self.listenerFactory = listenerFactory
    }

    public func setFrameHandler(_ handler: (@Sendable (Data) -> Void)?) {
        onFrame = handler
    }

    public func setStreamUnavailableHandler(_ handler: (@Sendable () -> Void)?) {
        onStreamUnavailable = handler
    }

    public func start(on port: UInt16) throws {
        guard let portValue = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "frame-stream-server", code: .min, userInfo: [NSLocalizedFailureErrorKey: "Invalid port \(port)"])
        }

        let listener = try listenerFactory.makeListener(portValue)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task {
                await self.handleNewConnection(connection)
            }
        }

        listener.stateUpdateHandler = { [state] listenerState in
            state.listenerState.value = listenerState
        }

        self.listener = listener
        listener.start(queue: connectionQueue)
    }

    public func disconnectClients(forcefully: Bool = false) {
        connections.forEach {
            cancelInactivityTimeout(for: $0)
            $0.stateUpdateHandler = nil
            if forcefully {
                $0.forceCancel()
            } else {
                $0.cancel()
            }
        }
        connections.removeAll()
        state.connectionState.value = .cancelled
        onStreamUnavailable?()
    }

    public func stop() {
        guard let listener else {
            return
        }
        listener.cancel()
        disconnectClients()
        listener.stateUpdateHandler = nil
        self.listener = nil
    }

    private func handleConnectionStateUpdate(_ connectionState: TransportConnectionState, for connection: any TransportConnection) {
        state.connectionState.value = connection.state

        switch connectionState {
        case .ready:
            scheduleInactivityTimeout(for: connection)
            receive(from: connection)
        case .waiting(let error):
            debugPrint("⏳ Connection waiting:", error)
            close(connection, cancel: true)
        case .failed(let error):
            debugPrint("❌ Connection failed:", error)
            close(connection, cancel: false)
        case .cancelled:
            debugPrint("🔌 Connection cancelled")
            close(connection, cancel: false)
        default:
            break
        }
    }

    private func bind(to connection: any TransportConnection) {
        connection.stateUpdateHandler = { [weak self] connectionState in
            guard let self else { return }
            Task { 
                await self.handleConnectionStateUpdate(connectionState, for: connection)
            }
        }
    }

    private func handleNewConnection(_ connection: any TransportConnection) {
        guard connections.isEmpty else {
            debugPrint("🚫 Rejecting additional client while another iOS stream is active")
            connection.forceCancel()
            return
        }

        connections.append(connection)
        bind(to: connection)
        connection.start(queue: connectionQueue)
    }

    private func remove(_ connection: any TransportConnection) {
        cancelInactivityTimeout(for: connection)
        connection.stateUpdateHandler = nil
        let connectionID = ObjectIdentifier(connection)
        connections.removeAll { ObjectIdentifier($0) == connectionID }
    }

    private func receive(from connection: any TransportConnection) {
        Task {
            await readSize(from: connection)
        }
    }

    private func cancelAndClose(_ connection: any TransportConnection) {
        close(connection, cancel: true)
    }

    private func readSize(from connection: any TransportConnection) async {
        let headerByteCount = FramePacket.headerByteCount
        let result: TransportReceiveResult
        do {
            result = try await connection.receive(
                minimumIncompleteLength: headerByteCount,
                maximumLength: headerByteCount
            )
        } catch {
            debugPrint("❌ Failed to read size:", error)
            cancelAndClose(connection)
            return
        }

        let header = result.data
        guard header.count == headerByteCount else {
            debugPrint("❌ Failed to read size: invalid header length \(header.count)")
            cancelAndClose(connection)
            return
        }

        let expectedSize = FramePacket.payloadSize(for: header)
        await readFrame(from: connection, expectedSize: expectedSize)
    }

    private func readFrame(from connection: any TransportConnection, expectedSize: Int) async {
        let result: TransportReceiveResult
        do {
            result = try await connection.receive(
                minimumIncompleteLength: expectedSize,
                maximumLength: expectedSize
            )
        } catch {
            debugPrint("❌ Failed to read frame:", error)
            cancelAndClose(connection)
            return
        }

        let frame = result.data
        guard frame.count == expectedSize else {
            debugPrint("❌ Failed to read frame: expected \(expectedSize) bytes, got \(frame.count)")
            cancelAndClose(connection)
            return
        }

        finishReceivingFrame(frame, from: connection)
    }

    private func finishReceivingFrame(_ frame: Data, from connection: any TransportConnection) {
        scheduleInactivityTimeout(for: connection)
        onFrame?(frame)
        receive(from: connection)
    }

    private func scheduleInactivityTimeout(for connection: any TransportConnection) {
        let identifier = ObjectIdentifier(connection)
        let workItem = DispatchWorkItem(flags: .enforceQoS) { [weak self] in
            guard let self else { return }
            
            Task {
                let connection = await self.connection(matching: identifier)
                guard let connection else { return }
                
                debugPrint("⏱️ No video frames received; closing stale connection")
                await self.close(connection, cancel: true)
            }
        }

        cancelInactivityTimeout(identifier: identifier)
        inactivityTimers[identifier] = workItem
        connectionQueue.asyncAfter(deadline: .now() + inactivityTimeout, execute: workItem)
    }
    
    private func cancelInactivityTimeout(identifier: ObjectIdentifier) {
        inactivityTimers.removeValue(forKey: identifier)?.cancel()
    }

    private func cancelInactivityTimeout(for connection: any TransportConnection) {
        let identifier = ObjectIdentifier(connection)
        cancelInactivityTimeout(identifier: identifier)
    }

    private func connection(matching identifier: ObjectIdentifier) -> (any TransportConnection)? {
        connections.first { ObjectIdentifier($0) == identifier }
    }

    private func close(_ connection: any TransportConnection, cancel: Bool) {
        if cancel {
            connection.cancel()
        }
        remove(connection)
        state.connectionState.value = .cancelled
        onStreamUnavailable?()
    }
}
