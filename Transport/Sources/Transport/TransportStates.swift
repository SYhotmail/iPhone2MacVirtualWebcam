import Foundation
import Network

public enum TransportNetworkError: Sendable, Equatable, CustomDebugStringConvertible {
    case posix(POSIXErrorCode)
    case dns(Int32)
    case tls(Int32)
    case wifiAware(Int32)

    init(_ error: NWError) {
        switch error {
        case .posix(let code):
            self = .posix(code)
        case .dns(let code):
            self = .dns(code)
        case .tls(let code):
            self = .tls(code)
        case .wifiAware(let code):
            self = .wifiAware(code)
        @unknown default:
            self = .posix(.ENOTRECOVERABLE)
        }
    }

    var nwError: NWError {
        switch self {
        case .posix(let code):
            return .posix(code)
        case .dns(let code):
            return .dns(code)
        case .tls(let code):
            return .tls(code)
        case .wifiAware(let code):
            if #available(macOS 26.0, iOS 26.0, *) {
                return .wifiAware(code)
            }
            return .posix(.ENOTSUP)
        }
    }

    public var debugDescription: String {
        switch self {
        case .posix(let code):
            return String(describing: code)
        case .dns(let code):
            return "DNS error \(code)"
        case .tls(let code):
            return "TLS error \(code)"
        case .wifiAware(let code):
            return "Wi-Fi Aware error \(code)"
        }
    }
}

public enum TransportConnectionState: Sendable, Equatable, CustomDebugStringConvertible {
    case setup
    case preparing
    case ready
    case waiting(TransportNetworkError)
    case failed(TransportNetworkError)
    case cancelled

    public init(_ state: NWConnection.State) {
        switch state {
        case .setup:
            self = .setup
        case .preparing:
            self = .preparing
        case .ready:
            self = .ready
        case .waiting(let error):
            self = .waiting(TransportNetworkError(error))
        case .failed(let error):
            self = .failed(TransportNetworkError(error))
        case .cancelled:
            self = .cancelled
        @unknown default:
            self = .preparing
        }
    }

    public var nwConnectionState: NWConnection.State {
        switch self {
        case .setup:
            return .setup
        case .preparing:
            return .preparing
        case .ready:
            return .ready
        case .waiting(let error):
            return .waiting(error.nwError)
        case .failed(let error):
            return .failed(error.nwError)
        case .cancelled:
            return .cancelled
        }
    }

    public var isConnected: Bool {
        if case .ready = self {
            return true
        }
        return false
    }

    public var debugDescription: String {
        switch self {
        case .setup:
            return "Setup"
        case .preparing:
            return "Preparing"
        case .ready:
            return "Ready"
        case .waiting(let error):
            return "Waiting: \(error.debugDescription)"
        case .failed(let error):
            return "Failed: \(error.debugDescription)"
        case .cancelled:
            return "Cancelled"
        }
    }
}

public enum TransportListenerState: Sendable, Equatable, CustomDebugStringConvertible {
    case setup
    case ready
    case waiting(TransportNetworkError)
    case failed(TransportNetworkError)
    case cancelled

    public init(_ state: NWListener.State) {
        switch state {
        case .setup:
            self = .setup
        case .ready:
            self = .ready
        case .waiting(let error):
            self = .waiting(TransportNetworkError(error))
        case .failed(let error):
            self = .failed(TransportNetworkError(error))
        case .cancelled:
            self = .cancelled
        @unknown default:
            self = .setup
        }
    }

    public var nwListenerState: NWListener.State {
        switch self {
        case .setup:
            return .setup
        case .ready:
            return .ready
        case .waiting(let error):
            return .waiting(error.nwError)
        case .failed(let error):
            return .failed(error.nwError)
        case .cancelled:
            return .cancelled
        }
    }

    public var isConnected: Bool {
        if case .ready = self {
            return true
        }
        return false
    }

    public var debugDescription: String {
        switch self {
        case .setup:
            return "Setup"
        case .ready:
            return "Ready"
        case .waiting(let error):
            return "Waiting: \(error.debugDescription)"
        case .failed(let error):
            return "Failed: \(error.debugDescription)"
        case .cancelled:
            return "Cancelled"
        }
    }
}
