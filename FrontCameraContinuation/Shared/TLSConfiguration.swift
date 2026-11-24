import Foundation
import Network
import Security
import Transport

nonisolated struct TLSConfiguration: Sendable {
    static let `default` = Self(transport: .commonQUIC)

    let transport: TransportNetworkProtocol
    let minimumTLSVersion: tls_protocol_version_t

    init(
        transport: TransportNetworkProtocol = .commonQUIC,
        minimumTLSVersion: tls_protocol_version_t = .TLSv13
    ) {
        self.transport = transport
        self.minimumTLSVersion = minimumTLSVersion
    }

    func makeServerParameters(identity: SecIdentity) throws -> NWParameters {
        try TransportTLSParameters.makeServerParameters(
            identity: identity,
            transport: transport,
            minimumTLSVersion: minimumTLSVersion
        )
    }
}
