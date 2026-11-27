import Foundation
import Network

public enum TransportNetworkProtocol: Sendable {
    case tcp
    case quic(alpn: [String] = [],
              direction: NWProtocolQUIC.Options.Direction = .bidirectional)
    
    public static var commonQUIC: Self {
        .quic(alpn: ["camera-lan-stream"], direction: .bidirectional)
    }
}

extension TransportNetworkProtocol {
    var nwParameters: NWParameters {
        switch self {
        case .tcp:
            return .tcp
        case .quic(let alpn, _):
            return .quic(alpn: alpn)
        }
    }
}

struct TransportReceiveResult: Sendable {
    let data: Data
    let contentContext: NWConnection.ContentContext?
    let isComplete: Bool
}

protocol TransportConnection: AnyObject, Sendable {
    var state: TransportConnectionState { get }
    var stateUpdateHandler: (@Sendable (TransportConnectionState) -> Void)? { get set }
    var pathUpdateHandler: (@Sendable (NWPath) -> Void)? { get set }
    var viabilityUpdateHandler: (@Sendable (Bool) -> Void)? { get set }
    var betterPathUpdateHandler: (@Sendable (Bool) -> Void)? { get set }

    func start(queue: DispatchQueue)
    func cancel()
    func forceCancel()
    func send(content: Data?) async throws
    func receive(minimumIncompleteLength: Int, maximumLength: Int) async throws -> TransportReceiveResult
    /// The QUIC datagram flow sharing this connection's tunnel, opened on first call.
    /// `nil` for transports without datagrams (TCP); frames then travel on the stream.
    func openDatagramFlow() -> (any TransportDatagramFlow)?
}

extension TransportConnection {
    func openDatagramFlow() -> (any TransportDatagramFlow)? {
        nil
    }
}

/// Unreliable, unordered messages that share a QUIC connection with the control stream.
protocol TransportDatagramFlow: AnyObject, Sendable {
    /// Largest datagram the current path carries.
    var maximumDatagramSize: Int { get }

    func start(queue: DispatchQueue)
    func cancel()
    /// Queues one datagram without waiting; datagrams may be dropped.
    func send(_ datagram: Data)
    func receive() async throws -> Data
}

final class NWConnectionAdapter: TransportConnection {
    private let connection: NWConnection
    /// The QUIC tunnel this stream belongs to; cancelled with the stream.
    private let group: NWConnectionGroup?
    /// Network.framework already started the connection (accepted QUIC streams).
    private let isStarted: Bool
    private let datagramFlowLock = NSLock()
    private var datagramFlow: NWDatagramFlowAdapter?

    init(connection: NWConnection, group: NWConnectionGroup? = nil, isStarted: Bool = false) {
        self.connection = connection
        self.group = group
        self.isStarted = isStarted
    }

    var state: TransportConnectionState {
        TransportConnectionState(connection.state)
    }

    var stateUpdateHandler: (@Sendable (TransportConnectionState) -> Void)? {
        get {
            guard let handler = connection.stateUpdateHandler else {
                return nil
            }
            return { state in
                handler(state.nwConnectionState)
            }
        }
        set {
            connection.stateUpdateHandler = { state in
                newValue?(TransportConnectionState(state))
            }
        }
    }

    var pathUpdateHandler: (@Sendable (NWPath) -> Void)? {
        get { connection.pathUpdateHandler }
        set { connection.pathUpdateHandler = newValue }
    }

    var viabilityUpdateHandler: (@Sendable (Bool) -> Void)? {
        get { connection.viabilityUpdateHandler }
        set { connection.viabilityUpdateHandler = newValue }
    }

    var betterPathUpdateHandler: (@Sendable (Bool) -> Void)? {
        get { connection.betterPathUpdateHandler }
        set { connection.betterPathUpdateHandler = newValue }
    }

    func start(queue: DispatchQueue) {
        guard isStarted else {
            connection.start(queue: queue)
            return
        }
        // Already running: report the current state as a fresh start would.
        let handler = stateUpdateHandler
        let state = state
        queue.async {
            handler?(state)
        }
    }

    func cancel() {
        connection.cancel()
        closeTunnel()
    }

    func forceCancel() {
        connection.forceCancel()
        closeTunnel()
    }

    private func closeTunnel() {
        datagramFlowLock.withLock { datagramFlow }?.cancel()
        group?.cancel()
    }

    func openDatagramFlow() -> (any TransportDatagramFlow)? {
        datagramFlowLock.withLock {
            if datagramFlow == nil, let flow = group?.extractDatagramFlow() {
                datagramFlow = NWDatagramFlowAdapter(connection: flow)
            }
            return datagramFlow
        }
    }

    func send(content: Data?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(
                content: content,
                contentContext: .defaultStream,
                isComplete: false,
                completion: .contentProcessed({ error in
                    continuation.resume(with: error.flatMap { .failure($0) } ?? .success(()))
                })
            )
        }
    }

    func receive(minimumIncompleteLength: Int, maximumLength: Int) async throws -> TransportReceiveResult {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: minimumIncompleteLength,
                maximumLength: maximumLength
            ) { data, contentContext, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: .init(data: data,
                                                         contentContext: contentContext,
                                                         isComplete: isComplete))
                } else {
                    continuation.resume(throwing: NSError(domain: "custom", code: .min))
                }
            }
        }
    }
}

extension NWConnectionAdapter: @unchecked Sendable {}

protocol TransportListener: AnyObject, Sendable {
    var state: TransportListenerState { get }
    var stateUpdateHandler: (@Sendable (TransportListenerState) -> Void)? { get set }
    var newConnectionHandler: (@Sendable (any TransportConnection) -> Void)? { get set }
    /// Bonjour service type matching this listener's transport (`_cam2mac._udp` or `_cam2mac._tcp`).
    var serviceType: String { get }
    /// Bonjour service to advertise; must be set before `start`.
    var service: NWListener.Service? { get set }
    /// Called with the service name actually registered (Bonjour may rename on conflicts).
    var serviceNameRegisteredHandler: (@Sendable (String) -> Void)? { get set }

    func start(queue: DispatchQueue)
    func cancel()
}

final class NWListenerAdapter: TransportListener {
    private let listener: NWListener
    /// QUIC listeners accept whole tunnels (stream + datagram flow) instead of single streams.
    private let acceptsQUICTunnels: Bool
    private let tunnelQueue = DispatchQueue(label: "transport.quic.tunnels")
    private var connectionHandler: (@Sendable (any TransportConnection) -> Void)?

    init(listener: NWListener) {
        self.listener = listener
        self.acceptsQUICTunnels = listener.parameters.defaultProtocolStack.transportProtocol is NWProtocolQUIC.Options
    }

    var state: TransportListenerState {
        TransportListenerState(listener.state)
    }

    var stateUpdateHandler: (@Sendable (TransportListenerState) -> Void)? {
        get {
            guard let handler = listener.stateUpdateHandler else {
                return nil
            }
            return { state in
                handler(state.nwListenerState)
            }
        }
        set {
            listener.stateUpdateHandler = { state in
                newValue?(TransportListenerState(state))
            }
        }
    }

    var newConnectionHandler: (@Sendable (any TransportConnection) -> Void)? {
        get { connectionHandler }
        set {
            connectionHandler = newValue
            if acceptsQUICTunnels {
                listener.newConnectionGroupHandler = { [tunnelQueue] group in
                    QUICTunnelAcceptor(group: group, queue: tunnelQueue) { stream in
                        newValue?(stream)
                    }.start()
                }
            } else {
                listener.newConnectionHandler = { connection in
                    newValue?(NWConnectionAdapter(connection: connection))
                }
            }
        }
    }

    var serviceType: String {
        acceptsQUICTunnels ? FrameStreamService.type : FrameStreamService.tcpType
    }

    var service: NWListener.Service? {
        get { listener.service }
        set { listener.service = newValue }
    }

    var serviceNameRegisteredHandler: (@Sendable (String) -> Void)? {
        didSet {
            let handler = serviceNameRegisteredHandler
            listener.serviceRegistrationUpdateHandler = { change in
                if case let .add(.service(name, _, _, _)) = change {
                    handler?(name)
                }
            }
        }
    }

    func start(queue: DispatchQueue) {
        listener.start(queue: queue)
    }

    func cancel() {
        listener.cancel()
    }
}

extension NWListenerAdapter: @unchecked Sendable {}

