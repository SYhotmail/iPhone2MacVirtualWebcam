import CryptoKit
import Foundation

/// Bonjour advertisement used by the Mac receiver.
public enum FrameStreamService {
    /// QUIC runs over UDP.
    public static let type = "_cam2mac._udp"
    public static let domain = "local."

    /// SHA-256 of a DER-encoded certificate. Clients pin this value.
    public static func fingerprint(ofCertificate der: Data) -> Data {
        Data(SHA256.hash(data: der))
    }
}

/// First packet a client sends on every connection.
public struct PairingHello: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// First connection: proves the client scanned the Mac's QR code and registers its secret.
        case pair
        /// Later connections: authenticates with the registered secret.
        case hello
    }

    public static let currentVersion = 2
    static let maximumEncodedSize = 4096

    public var version: Int
    public var kind: Kind
    public var clientID: UUID
    public var secret: Data
    public var token: Data?
    public var deviceName: String?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case kind = "type"
        case clientID
        case secret
        case token
        case deviceName = "name"
    }

    public static func pair(token: Data, clientID: UUID, secret: Data, deviceName: String) -> Self {
        .init(version: currentVersion, kind: .pair, clientID: clientID, secret: secret, token: token, deviceName: deviceName)
    }

    public static func hello(clientID: UUID, secret: Data) -> Self {
        .init(version: currentVersion, kind: .hello, clientID: clientID, secret: secret, token: nil, deviceName: nil)
    }

    /// The hello to use once pairing succeeded; pairing tokens are single-use.
    var afterPairing: Self {
        .hello(clientID: clientID, secret: secret)
    }
}

/// The receiver's answer to a `PairingHello`.
public struct PairingReply: Codable, Sendable, Equatable {
    public var ok: Bool
    public var reason: String?

    public static let accepted = Self(ok: true, reason: nil)

    public static func rejected(_ reason: String) -> Self {
        .init(ok: false, reason: reason)
    }
}

/// Contents of the QR code the Mac shows for pairing.
public struct PairingInvitation: Sendable, Equatable {
    public static let scheme = "cam2mac"
    private static let host = "pair"

    /// SHA-256 of the Mac's certificate.
    public let fingerprint: Data
    /// One-time pairing secret.
    public let token: Data
    /// Bonjour service name the Mac advertises.
    public let serviceName: String

    public init(fingerprint: Data, token: Data, serviceName: String) {
        self.fingerprint = fingerprint
        self.token = token
        self.serviceName = serviceName
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme,
              url.host == Self.host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let fingerprint = items.first(where: { $0.name == "fp" })?.value.flatMap(Data.init(hex:)),
              fingerprint.count == SHA256.byteCount,
              let token = items.first(where: { $0.name == "t" })?.value.flatMap(Data.init(hex:)),
              token.count >= 16,
              let serviceName = items.first(where: { $0.name == "n" })?.value,
              !serviceName.isEmpty else {
            return nil
        }
        self.init(fingerprint: fingerprint, token: token, serviceName: serviceName)
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            .init(name: "fp", value: fingerprint.hexString),
            .init(name: "t", value: token.hexString),
            .init(name: "n", value: serviceName),
        ]
        return components.url!
    }
}

extension Data {
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    public init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else {
            return nil
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
