import Foundation
import Network
import Transport

nonisolated struct TLSConfiguration: Sendable {
    static let `default` = Self(
        passcode: "cam2mac-lan-passcode",
        serviceLabel: "camera-lan-stream",
        transport: .commonQUIC
    )

    let passcode: String
    let serviceLabel: String
    let transport: TransportNetworkProtocol
    let minimumTLSVersion: tls_protocol_version_t

    init(
        passcode: String,
        serviceLabel: String,
        transport: TransportNetworkProtocol = .commonQUIC,
        minimumTLSVersion: tls_protocol_version_t = .TLSv13
    ) {
        self.passcode = passcode
        self.serviceLabel = serviceLabel
        self.transport = transport
        self.minimumTLSVersion = minimumTLSVersion
    }

    func makeClientParameters() throws -> NWParameters {
        try TransportTLSParameters.makeClientCertificateParameters(
            minimumTLSVersion: minimumTLSVersion,
            transport: transport
        )
    }

    func makeServerParameters() throws -> NWParameters {
        try TransportTLSParameters.makeServerCertificateParameters(
            minimumTLSVersion: minimumTLSVersion,
            transport: transport
        )
    }
}
