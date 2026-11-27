import Foundation
import Testing
@testable import Transport

/// Checks the Swift protocol code against `ProtocolFixtures/`, which the Android tests read too.
@Suite("Protocol fixtures")
struct ProtocolFixtureTests {
    private struct HelloCase: Decodable {
        var name: String
        var kind: String
        var clientID: String
        var secretHex: String
        var tokenHex: String?
        var deviceName: String?
        var json: JSONValue
    }

    @Test
    func helloEncodesToFixtureJSON() throws {
        let cases = try loadFixture("pairing-hello.json", key: "cases", as: [HelloCase].self)
        #expect(!cases.isEmpty)
        for fixture in cases {
            let clientID = try #require(UUID(uuidString: fixture.clientID))
            let secret = try #require(Data(hex: fixture.secretHex))
            let hello: PairingHello
            switch fixture.kind {
            case "pair":
                hello = .pair(
                    token: try #require(fixture.tokenHex.flatMap(Data.init(hex:))),
                    clientID: clientID,
                    secret: secret,
                    deviceName: try #require(fixture.deviceName)
                )
            default:
                hello = .hello(clientID: clientID, secret: secret)
            }

            let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(hello))
            #expect(encoded == fixture.json, "\(fixture.name)")

            let decoded = try JSONDecoder().decode(PairingHello.self, from: JSONEncoder().encode(fixture.json))
            #expect(decoded == hello, "\(fixture.name)")
        }
    }

    private struct ReplyCase: Decodable {
        var json: String
        var ok: Bool
        var reason: String?
        var encoded: Bool
    }

    @Test
    func replyMatchesFixtures() throws {
        let cases = try loadFixture("pairing-reply.json", key: "cases", as: [ReplyCase].self)
        #expect(!cases.isEmpty)
        for fixture in cases {
            let expected = PairingReply(ok: fixture.ok, reason: fixture.reason)
            #expect(try JSONDecoder().decode(PairingReply.self, from: Data(fixture.json.utf8)) == expected)
            if fixture.encoded {
                let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(expected))
                let wanted = try JSONDecoder().decode(JSONValue.self, from: Data(fixture.json.utf8))
                #expect(encoded == wanted, "\(fixture.json)")
            }
        }
    }

    private struct InvitationFixture: Decodable {
        struct Valid: Decodable {
            var url: String
            var fingerprintHex: String
            var tokenHex: String
            var serviceName: String
        }

        struct Invalid: Decodable {
            var url: String
            var why: String
        }

        var valid: [Valid]
        var invalid: [Invalid]
    }

    @Test
    func invitationMatchesFixtures() throws {
        let fixture = try loadFixture("pairing-invitation.json", as: InvitationFixture.self)
        #expect(!fixture.valid.isEmpty && !fixture.invalid.isEmpty)
        for valid in fixture.valid {
            let invitation = PairingInvitation(
                fingerprint: try #require(Data(hex: valid.fingerprintHex)),
                token: try #require(Data(hex: valid.tokenHex)),
                serviceName: valid.serviceName
            )
            #expect(invitation.url.absoluteString == valid.url, "generated URL for \(valid.serviceName)")
            #expect(PairingInvitation(url: try #require(URL(string: valid.url))) == invitation, "parse \(valid.url)")
        }
        for invalid in fixture.invalid {
            let parsed = URL(string: invalid.url).flatMap(PairingInvitation.init(url:))
            #expect(parsed == nil, "\(invalid.why): \(invalid.url)")
        }
    }

    private struct PacketCase: Decodable {
        var name: String
        var payloadHex: String
        var packetHex: String
    }

    @Test
    func framePacketMatchesFixtures() throws {
        let cases = try loadFixture("frame-packet.json", key: "cases", as: [PacketCase].self)
        #expect(!cases.isEmpty)
        for fixture in cases {
            let payload = try #require(Data(hex: fixture.payloadHex))
            let packet = try #require(Data(hex: fixture.packetHex))
            #expect(FramePacket.packetized(payload) == packet, "\(fixture.name)")
            #expect(FramePacket.payloadSize(for: packet.prefix(FramePacket.headerByteCount)) == payload.count, "\(fixture.name)")
        }
        #expect(StreamControlMessage.keyframeRequest.rawValue == 0x01)
    }
}

/// Any JSON value, compared structurally (key order and escaping don't matter).
private enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// Reads `ProtocolFixtures/<name>` at the repository root (shared with the Android tests).
private func loadFixture<T: Decodable>(_ name: String, key: String? = nil, as type: T.Type) throws -> T {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TransportTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // Transport
        .deletingLastPathComponent() // repository root
    let data = try Data(contentsOf: root.appending(path: "ProtocolFixtures/\(name)"))
    guard let key else {
        return try JSONDecoder().decode(T.self, from: data)
    }
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let value = try #require(object[key])
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
}
