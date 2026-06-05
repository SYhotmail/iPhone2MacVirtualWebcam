import Foundation
import Network

typealias TransportReceiveCompletion = @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void
typealias TransportSendCompletion = @Sendable (NWError?) -> Void

protocol TransportConnection: AnyObject, Sendable {
    var state: TransportConnectionState { get }
    var stateUpdateHandler: (@Sendable (TransportConnectionState) -> Void)? { get set }
    var pathUpdateHandler: (@Sendable (NWPath) -> Void)? { get set }
    var viabilityUpdateHandler: (@Sendable (Bool) -> Void)? { get set }
    var betterPathUpdateHandler: (@Sendable (Bool) -> Void)? { get set }

    func start(queue: DispatchQueue)
    func cancel()
    func forceCancel()
    func send(content: Data?, completion: @escaping TransportSendCompletion)
    func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping TransportReceiveCompletion
    )
}

final class NWConnectionAdapter: TransportConnection {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    var state: TransportConnectionState {
        TransportConnectionState(connection.state)
    }

    var stateUpdateHandler: (@Sendable (TransportConnectionState) -> Void)? {
        get { nil }
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
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    func forceCancel() {
        connection.forceCancel()
    }

    func send(content: Data?, completion: @escaping TransportSendCompletion) {
        connection.send(
            content: content,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed(completion)
        )
    }

    func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping TransportReceiveCompletion
    ) {
        connection.receive(
            minimumIncompleteLength: minimumIncompleteLength,
            maximumLength: maximumLength,
            completion: completion
        )
    }
}

extension NWConnectionAdapter: @unchecked Sendable {}

protocol TransportListener: AnyObject, Sendable {
    var state: TransportListenerState { get }
    var stateUpdateHandler: (@Sendable (TransportListenerState) -> Void)? { get set }
    var newConnectionHandler: (@Sendable (any TransportConnection) -> Void)? { get set }

    func start(queue: DispatchQueue)
    func cancel()
}

final class NWListenerAdapter: TransportListener {
    private let listener: NWListener

    init(listener: NWListener) {
        self.listener = listener
    }

    var state: TransportListenerState {
        TransportListenerState(listener.state)
    }

    var stateUpdateHandler: (@Sendable (TransportListenerState) -> Void)? {
        get { nil }
        set {
            listener.stateUpdateHandler = { state in
                newValue?(TransportListenerState(state))
            }
        }
    }

    var newConnectionHandler: (@Sendable (any TransportConnection) -> Void)? {
        get { nil }
        set {
            listener.newConnectionHandler = { connection in
                newValue?(NWConnectionAdapter(connection: connection))
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

struct NetworkConnectionFactory {
    let makeConnection: @Sendable (NWEndpoint.Host, NWEndpoint.Port) -> any TransportConnection

    static let live = Self { host, port in
        NWConnectionAdapter(connection: NWConnection(host: host, port: port, using: .tcp))
    }
}

struct NetworkListenerFactory {
    let makeListener: @Sendable (NWEndpoint.Port) throws -> any TransportListener

    static let live = Self { port in
        let listener = try NWListener(using: .tcp, on: port)
        return NWListenerAdapter(listener: listener)
    }
}
