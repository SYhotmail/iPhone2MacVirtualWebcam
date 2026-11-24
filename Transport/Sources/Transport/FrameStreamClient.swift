import Foundation
import Network

/// Sends packetized frame data to a paired receiver over the configured network transport.
///
/// After the transport becomes ready the client sends a `PairingHello` and only reports
/// `.connected` once the receiver accepts it.
public actor FrameStreamClient {
    public enum Status: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case failed
        /// The receiver refused the pairing credentials; reconnecting will not help.
        case rejected(reason: String?)
    }

    /// Where to connect and how to authenticate.
    public struct Destination: Sendable, Equatable {
        public var endpoint: NWEndpoint
        /// SHA-256 of the receiver certificate to pin.
        public var pinnedFingerprint: Data
        public var hello: PairingHello

        public init(endpoint: NWEndpoint, pinnedFingerprint: Data, hello: PairingHello) {
            self.endpoint = endpoint
            self.pinnedFingerprint = pinnedFingerprint
            self.hello = hello
        }

        /// A receiver advertised over Bonjour under `serviceName`.
        public static func service(named serviceName: String, pinnedFingerprint: Data, hello: PairingHello) -> Self {
            .init(
                endpoint: .service(name: serviceName, type: FrameStreamService.type, domain: FrameStreamService.domain, interface: nil),
                pinnedFingerprint: pinnedFingerprint,
                hello: hello
            )
        }

        /// A receiver at a fixed address; returns `nil` for an invalid port.
        public static func host(_ host: String, port: UInt16, pinnedFingerprint: Data, hello: PairingHello) -> Self? {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                return nil
            }
            return .init(endpoint: .hostPort(host: .init(host), port: nwPort), pinnedFingerprint: pinnedFingerprint, hello: hello)
        }
    }

    private var connection: (any TransportConnection)? {
        didSet {
            guard let oldValue, oldValue !== connection else {
                return
            }
            oldValue.cancel()
        }
    }

    typealias TransportConnectionFactory = @Sendable (Destination) -> any TransportConnection

    private var connectionID: ObjectIdentifier?
    private var currentDestination: Destination?
    private let connectionFactory: TransportConnectionFactory

    private var status: Status = .idle {
        didSet {
            guard oldValue != status else {
                return
            }
            onStatusChanged?(status)
            onConnectivityChanged?(status == .connected)
        }
    }

    private var onConnectivityChanged: (@Sendable (Bool) -> Void)? {
        didSet {
            guard let onConnectivityChanged else { return }
            onConnectivityChanged(status == .connected)
        }
    }

    private var onStatusChanged: (@Sendable (Status) -> Void)?

    public init(transport: TransportNetworkProtocol = .commonQUIC) {
        self.init { destination in
            let parameters = TransportTLSParameters.makeClientParameters(
                pinnedFingerprint: destination.pinnedFingerprint,
                transport: transport
            )
            return NWConnectionAdapter(connection: NWConnection(to: destination.endpoint, using: parameters))
        }
    }

    init(connectionFactory: @escaping TransportConnectionFactory) {
        self.connectionFactory = connectionFactory
    }

    public func setConnectivityChangedHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        onConnectivityChanged = handler
    }

    public func setStatusChangedHandler(_ handler: (@Sendable (Status) -> Void)?) {
        onStatusChanged = handler
    }

    public func connect(to destination: Destination) {
        currentDestination = destination
        connection = nil
        status = .connecting

        let connection = connectionFactory(destination)
        let connectionID = ObjectIdentifier(connection)
        self.connectionID = connectionID

        connection.stateUpdateHandler = { [weak self] newState in
            debugPrint("!!! New State \(newState)")
            guard let self else {
                return
            }

            Task {
                await self.handleStateUpdate(newState, sourceID: connectionID)
            }
        }
        connection.pathUpdateHandler = { newPath in
            debugPrint("!!! New Path \(newPath.debugDescription)")
        }
        connection.viabilityUpdateHandler = { isViable in
            debugPrint("!!! isViable \(isViable)")
        }
        connection.betterPathUpdateHandler = { newHasBetterPath in
            debugPrint("!!! newHasBetterPath \(newHasBetterPath)")
        }

        connection.start(queue: .global(qos: .userInitiated))
        self.connection = connection
    }

    @discardableResult
    public func reconnect() -> Bool {
        guard let currentDestination else {
            return false
        }
        connect(to: currentDestination)
        return true
    }

    public func disconnect() {
        connection = nil
        status = .idle
    }

    public func disconnectPreservingStatus() {
        connection = nil
    }

    /// Sends a video frame; dropped until the receiver accepted the hello.
    public func send(_ data: Data) async {
        guard let connection, status == .connected else {
            return
        }

        let packet = FramePacket.packetized(data)
        do {
            try await connection.send(content: packet)
        } catch {
            debugPrint("❌ Error: \(error.localizedDescription)")
        }
    }

    private func handleStateUpdate(_ newState: TransportConnectionState, sourceID: ObjectIdentifier) async {
        guard connectionID == sourceID else {
            return
        }
        if case .rejected = status {
            // The receiver closes the connection after rejecting; keep the rejection visible.
            return
        }

        switch newState {
        case .setup, .preparing:
            status = .connecting
        case .waiting(let error):
            debugPrint("❌ Connection waiting error: \(error)")
            status = .failed
        case .ready:
            await performHandshake(sourceID: sourceID)
        case .failed(let error):
            debugPrint("❌ Failed error: \(error)")
            status = .failed
        case .cancelled:
            status = .idle
        }
    }

    private func performHandshake(sourceID: ObjectIdentifier) async {
        guard let connection, let destination = currentDestination else {
            return
        }

        let reply: PairingReply
        do {
            try await connection.send(content: FramePacket.packetized(JSONEncoder().encode(destination.hello)))
            let payload = try await FramePacket.read(from: connection, maximumPayloadSize: PairingHello.maximumEncodedSize)
            reply = try JSONDecoder().decode(PairingReply.self, from: payload)
        } catch {
            debugPrint("❌ Handshake failed: \(error)")
            if connectionID == sourceID {
                status = .failed
            }
            return
        }

        guard connectionID == sourceID else {
            return
        }

        if reply.ok {
            currentDestination?.hello = destination.hello.afterPairing
            status = .connected
        } else {
            status = .rejected(reason: reply.reason)
            self.connection = nil
        }
    }
}
