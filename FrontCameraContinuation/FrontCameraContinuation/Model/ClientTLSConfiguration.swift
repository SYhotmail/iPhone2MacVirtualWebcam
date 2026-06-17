import Foundation
import Network
import Transport

nonisolated struct ClientTLSConfiguration: Sendable {
    static let `default` = Self(
        pinnedServerPublicKeyHashBase64: "fpnYZihLev8u7OntmhGhJgr4Gf2GrFhV6sht7Gp84dk="
    )

    let pinnedServerPublicKeyHashBase64: String
    let minimumTLSVersion: tls_protocol_version_t

    init(
        pinnedServerPublicKeyHashBase64: String,
        minimumTLSVersion: tls_protocol_version_t = .TLSv13
    ) {
        self.pinnedServerPublicKeyHashBase64 = pinnedServerPublicKeyHashBase64
        self.minimumTLSVersion = minimumTLSVersion
    }

    func makeParameters() throws -> NWParameters {
        try TransportTLSParameters.makeClientParameters(
            pinnedServerPublicKeyHashBase64: pinnedServerPublicKeyHashBase64,
            minimumTLSVersion: minimumTLSVersion
        )
    }
}
