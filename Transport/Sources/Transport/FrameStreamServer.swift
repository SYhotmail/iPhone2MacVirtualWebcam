import Combine
import Foundation
import Network

/// Shared observable server state for UI-facing consumers.
public final class FrameStreamServerState: @unchecked Sendable {
    public let connectionState = CurrentValueSubject<TransportConnectionState, Never>(.setup)
    public let listenerState = CurrentValueSubject<TransportListenerState, Never>(.setup)
    /// Bonjour name the listener is currently registered under, if advertising.
    public let advertisedServiceName = CurrentValueSubject<String?, Never>(nil)

    public init() {}
}

/// Receives packetized frame data from a single client over the configured network transport.
///
/// Every connection must first send a `PairingHello`; frames are only accepted after the
/// injected authorizer approves it.
public actor FrameStreamServer {
    public typealias HelloAuthorizer = @Sendable (PairingHello) async -> PairingReply

    public nonisolated let state: FrameStreamServerState
    private var helloAuthorizer: HelloAuthorizer?

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
    private var streamingConnectionIDs = Set<ObjectIdentifier>()
    private let inactivityTimeout: TimeInterval = 2
    private let connectionQueue = DispatchQueue.global(qos: .userInitiated)
    typealias TransportListenerFactory = @Sendable (NWEndpoint.Port) throws -> any TransportListener
    public typealias NWListenerFactory = @Sendable (NWEndpoint.Port) throws -> NWListener
    private let listenerFactory: TransportListenerFactory

    public init(transport: TransportNetworkProtocol = .tcp) {
        let parameters = transport.nwParameters
        self.init { port in
            let listener = try NWListener(using: parameters, on: port)
            return NWListenerAdapter(listener: listener)
        }
    }

    public init(listenerBuilder: @escaping NWListenerFactory) {
        self.init { port in
            try NWListenerAdapter(listener: listenerBuilder(port))
        }
    }

    init(listenerFactory: @escaping TransportListenerFactory) {
        self.state = FrameStreamServerState()
        self.listenerFactory = listenerFactory
    }

    public func setFrameHandler(_ handler: (@Sendable (Data) -> Void)?) {
        onFrame = handler
    }

    public func setHelloAuthorizer(_ authorizer: HelloAuthorizer?) {
        helloAuthorizer = authorizer
    }

    public func setStreamUnavailableHandler(_ handler: (@Sendable () -> Void)?) {
        onStreamUnavailable = handler
    }

    /// Starts listening on `port`, advertising `serviceName` over Bonjour when given.
    public func start(on port: UInt16, serviceName: String? = nil) throws {
        guard let portValue = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "frame-stream-server", code: .min, userInfo: [NSLocalizedFailureErrorKey: "Invalid port \(port)"])
        }

        let listener = try listenerFactory(portValue)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task {
                await self.handleNewConnection(connection)
            }
        }

        listener.stateUpdateHandler = { [state] listenerState in
            state.listenerState.value = listenerState
        }

        if let serviceName {
            listener.service = NWListener.Service(name: serviceName, type: FrameStreamService.type)
            listener.serviceNameRegisteredHandler = { [state] name in
                state.advertisedServiceName.value = name
            }
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
        state.advertisedServiceName.value = nil
    }

    private func handleConnectionStateUpdate(_ connectionState: TransportConnectionState, for connection: any TransportConnection) {
        state.connectionState.value = connection.state

        switch connectionState {
        case .ready:
            scheduleInactivityTimeout(for: connection)
            Task {
                await authenticate(connection)
            }
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
        if let existingConnection = connections.first {
            let existingConnectionID = ObjectIdentifier(existingConnection)
            if streamingConnectionIDs.contains(existingConnectionID) {
                debugPrint("🚫 Rejecting additional client while another iOS stream is active")
                connection.forceCancel()
                return
            }

            close(existingConnection, cancel: true)
        }

        connections.append(connection)
        bind(to: connection)
        connection.start(queue: connectionQueue)
    }

    private func remove(_ connection: any TransportConnection) {
        cancelInactivityTimeout(for: connection)
        connection.stateUpdateHandler = nil
        let connectionID = ObjectIdentifier(connection)
        streamingConnectionIDs.remove(connectionID)
        connections.removeAll { ObjectIdentifier($0) == connectionID }
    }

    private func authenticate(_ connection: any TransportConnection) async {
        let reply: PairingReply
        do {
            let payload = try await FramePacket.read(from: connection, maximumPayloadSize: PairingHello.maximumEncodedSize)
            let hello = try JSONDecoder().decode(PairingHello.self, from: payload)
            if hello.version != PairingHello.currentVersion {
                reply = .rejected("Unsupported protocol version \(hello.version)")
            } else if let helloAuthorizer {
                reply = await helloAuthorizer(hello)
            } else {
                reply = .rejected("Receiver is not accepting connections")
            }
        } catch {
            debugPrint("❌ Failed to read hello:", error)
            cancelAndClose(connection)
            return
        }

        guard self.connection(matching: ObjectIdentifier(connection)) != nil else {
            return
        }

        do {
            try await connection.send(content: FramePacket.packetized(JSONEncoder().encode(reply)))
        } catch {
            debugPrint("❌ Failed to send hello reply:", error)
            cancelAndClose(connection)
            return
        }

        guard reply.ok else {
            debugPrint("🚫 Rejected client:", reply.reason ?? "")
            cancelAndClose(connection)
            return
        }

        scheduleInactivityTimeout(for: connection)
        receive(from: connection)
    }

    private func receive(from connection: any TransportConnection) {
        Task {
            await readFrame(from: connection)
        }
    }

    private func cancelAndClose(_ connection: any TransportConnection) {
        close(connection, cancel: true)
    }

    private func readFrame(from connection: any TransportConnection) async {
        let frame: Data
        do {
            frame = try await FramePacket.read(from: connection)
        } catch {
            debugPrint("❌ Failed to read frame:", error)
            cancelAndClose(connection)
            return
        }

        finishReceivingFrame(frame, from: connection)
    }

    private func finishReceivingFrame(_ frame: Data, from connection: any TransportConnection) {
        streamingConnectionIDs.insert(ObjectIdentifier(connection))
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
