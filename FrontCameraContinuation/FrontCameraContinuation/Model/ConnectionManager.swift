import Combine
import Foundation
import Network

final class ConnectionManager {
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

    let isConnectedPublisher = CurrentValueSubject<Bool, Never>(false)
    var onConnectionFailed: (() -> Void)?

    @discardableResult
    func connect(host: String, port: UInt16) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return false
        }

        currentHost = host
        currentPort = port
        connection = nil

        let endpoint = NWEndpoint.Host(host)
        let connection = NWConnection(host: endpoint, port: nwPort, using: .tcp)

        connection.stateUpdateHandler = { [weak self] newState in
            debugPrint("!!! New State \(newState)")
            let isReady: Bool
            if case .ready = newState {
                isReady = true
            } else {
                isReady = false
                if case .failed = newState {
                    self?.onConnectionFailed?()
                }
            }
            self?.isConnectedPublisher.value = isReady
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

        connection.start(queue: .global())
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
        isConnectedPublisher.value = false
    }

    func sendPacketized(_ data: Data) {
        let packet = packetizedData(data)
        connection?.send(content: packet, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed({ error in
            guard let error else { return }
            debugPrint("!!! Error: \(error.localizedDescription)")
            _ = error.errorCode == 57 || error.errorCode == 54
        }))
    }

    private func packetizedData(_ data: Data) -> Data {
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
