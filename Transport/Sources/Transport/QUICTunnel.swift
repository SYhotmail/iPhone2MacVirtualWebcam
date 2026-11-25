import Foundation
import Network

// A QUIC connection ("tunnel") between iPhone and Mac carries one bidirectional stream for
// pairing and control messages, and one datagram flow for video. Network.framework models the
// tunnel as an `NWConnectionGroup` with an `NWMultiplexGroup` descriptor.

extension NWConnectionGroup {
    /// Opens the tunnel's datagram flow. QUIC allows one per connection.
    ///
    /// The flow must use the group's own QUIC options (with `isDatagram` set); fresh options fail
    /// with "could not find protocol to join".
    func extractDatagramFlow() -> NWConnection? {
        guard let options = parameters.defaultProtocolStack.transportProtocol as? NWProtocolQUIC.Options else {
            return nil
        }
        options.isDatagram = true
        defer { options.isDatagram = false }
        return extract(connectionTo: nil, using: options)
    }
}

final class NWDatagramFlowAdapter: TransportDatagramFlow, @unchecked Sendable {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    var maximumDatagramSize: Int {
        let metadata = connection.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
        let usable = metadata?.usableDatagramFrameSize ?? 0
        return usable > 0 ? usable : VideoDatagram.fallbackMaximumDatagramSize
    }

    func start(queue: DispatchQueue) {
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ datagram: Data) {
        // Fire and forget: waiting for each datagram would stall the sender behind a slow path,
        // and a lost datagram is handled by the receiver anyway.
        connection.send(content: datagram, completion: .idempotent)
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: NWError.posix(.ENOTCONN))
                }
            }
        }
    }
}

/// Server side: turns an incoming tunnel into the `TransportConnection` for its control stream.
///
/// A client's multiplex group also opens an implicit stream that never carries data, so the
/// first stream to become ready is the control stream and the others are cancelled.
final class QUICTunnelAcceptor: @unchecked Sendable {
    private let group: NWConnectionGroup
    private let queue: DispatchQueue
    private let onControlStream: (NWConnectionAdapter) -> Void
    // Confined to `queue`.
    private var candidates = [NWConnection]()
    private var hasControlStream = false

    init(group: NWConnectionGroup, queue: DispatchQueue, onControlStream: @escaping (NWConnectionAdapter) -> Void) {
        self.group = group
        self.queue = queue
        self.onControlStream = onControlStream
    }

    /// The acceptor keeps itself alive through the group's handlers until the group ends.
    func start() {
        group.newConnectionHandler = { [self] stream in
            accept(stream)
        }
        group.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled:
                candidates.forEach { $0.cancel() }
                candidates.removeAll()
                group.newConnectionHandler = nil
                group.stateUpdateHandler = nil
            default:
                break
            }
        }
        group.start(queue: queue)
    }

    private func accept(_ stream: NWConnection) {
        guard !hasControlStream else {
            stream.cancel()
            return
        }
        candidates.append(stream)
        stream.stateUpdateHandler = { [weak self, weak stream] state in
            guard let self, let stream else { return }
            switch state {
            case .ready:
                select(stream)
            case .failed, .cancelled:
                candidates.removeAll { $0 === stream }
            default:
                break
            }
        }
        stream.start(queue: queue)
    }

    private func select(_ stream: NWConnection) {
        guard !hasControlStream else { return }
        hasControlStream = true
        candidates.filter { $0 !== stream }.forEach { $0.cancel() }
        candidates.removeAll()
        stream.stateUpdateHandler = nil
        onControlStream(NWConnectionAdapter(connection: stream, group: group, isStarted: true))
    }
}

/// Client side: a QUIC tunnel to the receiver, exposing its control stream as a `TransportConnection`.
final class QUICClientConnection: TransportConnection, @unchecked Sendable {
    /// A multiplex group reports `waiting` for a moment before `ready` even on a healthy path;
    /// only a wait longer than this is reported.
    static let waitingGracePeriod: TimeInterval = 2

    private let group: NWConnectionGroup
    private let lock = NSLock()
    private var stream: NWConnectionAdapter?
    private var queue: DispatchQueue?
    private var pendingWaitingReport: DispatchWorkItem?
    private var _state: TransportConnectionState = .setup
    private var _stateUpdateHandler: (@Sendable (TransportConnectionState) -> Void)?

    var pathUpdateHandler: (@Sendable (NWPath) -> Void)?
    var viabilityUpdateHandler: (@Sendable (Bool) -> Void)?
    var betterPathUpdateHandler: (@Sendable (Bool) -> Void)?

    init(to endpoint: NWEndpoint, using parameters: NWParameters) {
        group = NWConnectionGroup(with: NWMultiplexGroup(to: endpoint), using: parameters)
    }

    var state: TransportConnectionState {
        lock.withLock { _state }
    }

    var stateUpdateHandler: (@Sendable (TransportConnectionState) -> Void)? {
        get { lock.withLock { _stateUpdateHandler } }
        set { lock.withLock { _stateUpdateHandler = newValue } }
    }

    func start(queue: DispatchQueue) {
        lock.withLock { self.queue = queue }
        // The receiver never opens streams, but a group won't start without a handler.
        group.newConnectionHandler = { $0.cancel() }
        group.stateUpdateHandler = { [weak self] state in
            self?.handleGroupState(state)
        }
        report(.preparing)
        group.start(queue: queue)
    }

    func cancel() {
        lock.withLock { stream }?.cancel()
        group.cancel()
    }

    func forceCancel() {
        lock.withLock { stream }?.forceCancel()
        group.cancel()
    }

    func send(content: Data?) async throws {
        try await requireStream().send(content: content)
    }

    func receive(minimumIncompleteLength: Int, maximumLength: Int) async throws -> TransportReceiveResult {
        try await requireStream().receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength)
    }

    func openDatagramFlow() -> (any TransportDatagramFlow)? {
        lock.withLock { stream }?.openDatagramFlow()
    }

    private func requireStream() throws -> NWConnectionAdapter {
        guard let stream = lock.withLock({ stream }) else {
            throw NWError.posix(.ENOTCONN)
        }
        return stream
    }

    private func handleGroupState(_ state: NWConnectionGroup.State) {
        switch state {
        case .waiting(let error):
            scheduleWaitingReport(error)
        case .ready:
            cancelWaitingReport()
            openControlStream()
        case .failed(let error):
            cancelWaitingReport()
            report(.failed(TransportNetworkError(error)))
        case .cancelled:
            cancelWaitingReport()
            report(.cancelled)
        default:
            break
        }
    }

    private func openControlStream() {
        guard let queue = lock.withLock({ stream == nil ? self.queue : nil }),
              let connection = NWConnection(from: group) else {
            return
        }
        let stream = NWConnectionAdapter(connection: connection, group: group)
        stream.pathUpdateHandler = pathUpdateHandler
        stream.viabilityUpdateHandler = viabilityUpdateHandler
        stream.betterPathUpdateHandler = betterPathUpdateHandler
        stream.stateUpdateHandler = { [weak self] state in
            if state != .setup {
                self?.report(state)
            }
        }
        lock.withLock { self.stream = stream }
        stream.start(queue: queue)
    }

    private func scheduleWaitingReport(_ error: NWError) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.report(.waiting(TransportNetworkError(error)))
        }
        let queue = lock.withLock {
            pendingWaitingReport?.cancel()
            pendingWaitingReport = workItem
            return self.queue
        }
        queue?.asyncAfter(deadline: .now() + Self.waitingGracePeriod, execute: workItem)
    }

    private func cancelWaitingReport() {
        lock.withLock {
            pendingWaitingReport?.cancel()
            pendingWaitingReport = nil
        }
    }

    private func report(_ state: TransportConnectionState) {
        let handler = lock.withLock {
            _state = state
            return _stateUpdateHandler
        }
        handler?(state)
    }
}
