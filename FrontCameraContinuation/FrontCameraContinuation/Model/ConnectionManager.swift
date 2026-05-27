import Combine
import Foundation
import Network

nonisolated
final class ConnectionManager: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case failed
    }

    private var connection: NWConnection? {
        didSet {
            guard let oldValue, oldValue !== connection else {
                return
            }
            oldValue.cancel()
        }
    }
    private var currentHost: String?
    private var currentPort: UInt16?

    private var status: Status = .idle {
        didSet {
            guard oldValue != status else {
                return
            }
            onConnectionStatusChanged?(status)
            onConnectionChaged?(status == .connected)
        }
    }

    var onConnectionChaged: (@Sendable (Bool) -> Void)! {
        didSet {
            guard let onConnectionChaged else { return }
            onConnectionChaged(status == .connected)
        }
    }
    var onConnectionStatusChanged: (@Sendable (Status) -> Void)!
    
    @discardableResult
    func connect(host: String, port: UInt16) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            status = .failed
            return false
        }

        currentHost = host
        currentPort = port
        connection = nil
        status = .connecting

        let endpoint = NWEndpoint.Host(host)
        let connection = NWConnection(host: endpoint, port: nwPort, using: .tcp)

        connection.stateUpdateHandler = { [weak self, connection] newState in
            debugPrint("!!! New State \(newState)")
            guard let self else { return }
            guard self.connection === connection else {
                return
            }
            switch newState {
            case .setup, .preparing:
                self.status = .connecting
            case .waiting(let error):
                debugPrint("!!! Connection waiting: \(error)")
                self.status = .failed
            case .ready:
                self.status = .connected
            case .failed(_):
                self.status = .failed
            case .cancelled:
                self.status = .idle
            @unknown default:
                self.status = .connecting
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
    func reconnectCurrent() -> Bool {
        guard let currentHost, let currentPort else {
            return false
        }
        return connect(host: currentHost, port: currentPort)
    }

    func disconnect() {
        connection = nil
        status = .idle
    }

    func disconnectPreservingStatus() {
        connection = nil
    }

    func send(_ data: Data) {
        let packet = Self.packetizedData(data)
        connection?.send(content: packet, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed({ error in
            guard let error else { return }
            debugPrint("❌ Error: \(error.localizedDescription)")
            _ = error.errorCode == 57 || error.errorCode == 54
        }))
    }

    private static func packetizedData(_ data: Data) -> Data {
        let capacity = data.count
        var size = UInt32(capacity).bigEndian //TODO: think about capacity writer...
        var packet = Data()
        packet.reserveCapacity(4 + capacity)
        withUnsafeBytes(of: &size) { headerBuffer in
            packet.append(contentsOf: headerBuffer)
        }
        packet.append(data)
        return packet
    }
}
