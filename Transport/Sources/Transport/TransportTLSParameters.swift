import Foundation
import Network
import Security

public enum TransportTLSParameters {
    /// Largest QUIC datagram frame this side accepts; the path MTU limits real datagrams further.
    static let maximumDatagramFrameSize = 65535

    /// Client parameters that accept only the server certificate whose SHA-256 matches `pinnedFingerprint`.
    nonisolated public static func makeClientParameters(
        pinnedFingerprint: Data,
        transport: TransportNetworkProtocol = .commonQUIC,
        minimumTLSVersion: tls_protocol_version_t = .TLSv13
    ) -> NWParameters {
        makeParameters(transport: transport) { securityOptions, isQUIC in
            sec_protocol_options_set_min_tls_protocol_version(
                securityOptions,
                isQUIC ? quicMinimumTLSVersion(requested: minimumTLSVersion) : minimumTLSVersion
            )
            sec_protocol_options_set_verify_block(
                securityOptions,
                { _, trust, complete in
                    complete(leafCertificateMatches(trust: sec_trust_copy_ref(trust).takeRetainedValue(),
                                                    pinnedFingerprint: pinnedFingerprint))
                },
                DispatchQueue.global(qos: .userInitiated)
            )
        }
    }

    /// Server parameters presenting the receiver's own identity.
    nonisolated public static func makeServerParameters(
        identity: SecIdentity,
        transport: TransportNetworkProtocol = .commonQUIC,
        minimumTLSVersion: tls_protocol_version_t = .TLSv13
    ) throws -> NWParameters {
        guard let secIdentity = sec_identity_create(identity) else {
            throw NSError(domain: "transport.tls", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to wrap the receiver identity"
            ])
        }

        return makeParameters(transport: transport) { securityOptions, isQUIC in
            sec_protocol_options_set_min_tls_protocol_version(
                securityOptions,
                isQUIC ? quicMinimumTLSVersion(requested: minimumTLSVersion) : minimumTLSVersion
            )
            sec_protocol_options_set_local_identity(securityOptions, secIdentity)
        }
    }

    static func leafCertificateMatches(trust: SecTrust, pinnedFingerprint: Data) -> Bool {
        guard let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return false
        }
        let der = SecCertificateCopyData(certificate) as Data
        return FrameStreamService.fingerprint(ofCertificate: der) == pinnedFingerprint
    }

    private static func makeParameters(
        transport: TransportNetworkProtocol,
        configure: (sec_protocol_options_t, _ isQUIC: Bool) -> Void
    ) -> NWParameters {
        let parameters: NWParameters
        switch transport {
        case .tcp:
            let tlsOptions = NWProtocolTLS.Options()
            configure(tlsOptions.securityProtocolOptions, false)
            parameters = .init(tls: tlsOptions, tcp: .init())
        case let .quic(alpn, direction):
            let quicOptions = NWProtocolQUIC.Options(alpn: alpn)
            quicOptions.direction = direction
            // Advertise datagram support (RFC 9221); video frames travel as datagrams.
            quicOptions.maxDatagramFrameSize = Self.maximumDatagramFrameSize
            configure(quicOptions.securityProtocolOptions, true)
            parameters = .init(quic: quicOptions)
        }
        // Advertise and connect over Apple peer-to-peer Wi-Fi (AWDL) too, so the
        // iPhone finds the Mac without a shared Wi-Fi network. Both sides need it.
        parameters.includePeerToPeer = true
        // Live camera feed: Wi-Fi video access category and latency-sensitive scheduling.
        parameters.serviceClass = .interactiveVideo
        return parameters
    }

    private static func quicMinimumTLSVersion(requested: tls_protocol_version_t) -> tls_protocol_version_t {
        switch requested {
        case .TLSv10, .TLSv11, .TLSv12:
            return .TLSv13
        default:
            return requested
        }
    }
}
