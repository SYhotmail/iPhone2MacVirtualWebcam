import Foundation
import Network
import Transport

nonisolated struct TLSConfiguration: Sendable {
    static let `default` = Self(
        passcode: "cam2mac-lan-passcode",
        serviceLabel: "camera-lan-stream"
    )

    let passcode: String
    let serviceLabel: String
    let minimumTLSVersion: tls_protocol_version_t

    init(
        passcode: String,
        serviceLabel: String,
        minimumTLSVersion: tls_protocol_version_t = .TLSv12
    ) {
        self.passcode = passcode
        self.serviceLabel = serviceLabel
        self.minimumTLSVersion = minimumTLSVersion
    }

    func makeParameters() -> NWParameters {
        TransportTLSParameters.makePreSharedKeyParameters(
            passcode: passcode,
            serviceLabel: serviceLabel,
            minimumTLSVersion: minimumTLSVersion
        )
    }
}
