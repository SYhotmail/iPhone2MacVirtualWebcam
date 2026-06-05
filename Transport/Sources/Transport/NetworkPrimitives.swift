import Foundation
import Network

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
}

final class NWConnectionAdapter: TransportConnection {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    fileprivate var rawConnection: NWConnection {
        connection
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
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    func forceCancel() {
        connection.forceCancel()
    }

    func send(content: Data?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(
                content: content,
                contentContext: .defaultMessage,
                isComplete: true,
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
        get {
            guard let handler = listener.newConnectionHandler else {
                return nil
            }
            return { connection in
                if let connection = connection as? NWConnectionAdapter {
                    handler(connection.rawConnection)
                }
            }
        }
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
        let connection = NWConnection(host: host, port: port, using: .tcp)
        return NWConnectionAdapter(connection: connection)
    }
}

struct NetworkListenerFactory {
    let makeListener: @Sendable (NWEndpoint.Port) throws -> any TransportListener

    static let live = Self { port in
        let listener = try NWListener(using: .tcp, on: port)
        return NWListenerAdapter(listener: listener)
    }
}
