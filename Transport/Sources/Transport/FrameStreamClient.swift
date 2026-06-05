import Foundation
import Network

/// Sends packetized frame data to a remote receiver over TCP.
public actor FrameStreamClient {
    public enum Status: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case failed
    }

    private var connection: (any TransportConnection)? {
        didSet {
            guard let oldValue, oldValue !== connection else {
                return
            }
            oldValue.cancel()
        }
    }
    private var connectionID: ObjectIdentifier?
    private var currentHost: String?
    private var currentPort: UInt16?
    private let connectionFactory: NetworkConnectionFactory

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

    public init() {
        self.connectionFactory = .live
    }

    init(connectionFactory: NetworkConnectionFactory) {
        self.connectionFactory = connectionFactory
    }

    public static func accepts(port: UInt16) -> Bool {
        newPort(port: port) != nil
    }
    
    private static func newPort(port: UInt16) -> NWEndpoint.Port! {
        NWEndpoint.Port(rawValue: port)
    }

    public func setConnectivityChangedHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        onConnectivityChanged = handler
    }

    public func setStatusChangedHandler(_ handler: (@Sendable (Status) -> Void)?) {
        onStatusChanged = handler
    }

    @discardableResult
    public func connect(toHost host: String, port: UInt16) -> Bool {
        guard let nwPort = Self.newPort(port: port) else {
            status = .failed
            return false
        }

        currentHost = host
        currentPort = port
        connection = nil
        status = .connecting

        let endpoint = NWEndpoint.Host(host)
        let connection = connectionFactory.makeConnection(endpoint, nwPort)
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
        return true
    }

    @discardableResult
    public func reconnect() -> Bool {
        guard let currentHost, let currentPort else {
            return false
        }
        return connect(toHost: currentHost, port: currentPort)
    }

    public func disconnect() {
        connection = nil
        status = .idle
    }

    public func disconnectPreservingStatus() {
        connection = nil
    }

    public func send(_ data: Data) async {
        guard let connection else {
            return
        }

        let packet = FramePacket.packetized(data)
        do {
            try await connection.send(content: packet)
        } catch {
            debugPrint("❌ Error: \(error.localizedDescription)")
        }
    }

    private func handleStateUpdate(_ newState: TransportConnectionState, sourceID: ObjectIdentifier) {
        guard connectionID == sourceID else {
            return
        }

        switch newState {
        case .setup, .preparing:
            status = .connecting
        case .waiting(let error):
            debugPrint("❌ Connection waiting error: \(error)")
            status = .failed
        case .ready:
            status = .connected
        case .failed(let error):
            debugPrint("❌ Failed error: \(error)")
            status = .failed
        case .cancelled:
            status = .idle
        }
    }
}
