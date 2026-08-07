import Foundation
import Network
import Security

public enum TransportTLSParameters {
    private enum Resource {
        static let certificateName = "cam2mac-local-server"
        static let certificateExtension = "cer"
        static let identityExtension = "p12"
        static let identityPassword = "cam2mac-local-cert"
    }

    nonisolated public static func makeClientCertificateParameters(
        minimumTLSVersion: tls_protocol_version_t = .TLSv13,
        transport: TransportNetworkProtocol = .commonQUIC
    ) throws -> NWParameters {
        let pinnedCertificateData = try bundledCertificateData()

        switch transport {
        case .tcp:
            let tlsOptions = NWProtocolTLS.Options()
            configurePinnedCertificateVerification(
                tlsOptions.securityProtocolOptions,
                pinnedCertificateData: pinnedCertificateData,
                minimumTLSVersion: minimumTLSVersion
            )
            return .init(tls: tlsOptions, tcp: .init())
        case .quic(let alpn, let direction):
            let quicOptions = NWProtocolQUIC.Options(alpn: alpn)
            quicOptions.direction = direction
            configurePinnedCertificateVerification(
                quicOptions.securityProtocolOptions,
                pinnedCertificateData: pinnedCertificateData,
                minimumTLSVersion: quicMinimumTLSVersion(requested: minimumTLSVersion)
            )
            return .init(quic: quicOptions)
        }
    }

    nonisolated public static func makeServerCertificateParameters(
        minimumTLSVersion: tls_protocol_version_t = .TLSv13,
        transport: TransportNetworkProtocol = .commonQUIC
    ) throws -> NWParameters {
        let identity = try bundledLocalIdentity()

        switch transport {
        case .tcp:
            let tlsOptions = NWProtocolTLS.Options()
            configureLocalIdentity(
                tlsOptions.securityProtocolOptions,
                identity: identity,
                minimumTLSVersion: minimumTLSVersion
            )
            return .init(tls: tlsOptions, tcp: .init())
        case let .quic(alpn, direction):
            let quicOptions = NWProtocolQUIC.Options(alpn: alpn)
            quicOptions.direction = direction
            configureLocalIdentity(
                quicOptions.securityProtocolOptions,
                identity: identity,
                minimumTLSVersion: quicMinimumTLSVersion(requested: minimumTLSVersion)
            )
            return .init(quic: quicOptions)
        }
    }
    private static func quicMinimumTLSVersion(requested: tls_protocol_version_t) -> tls_protocol_version_t {
        switch requested {
        case .TLSv10, .TLSv11, .TLSv12:
            return .TLSv13
        default:
            return requested
        }
    }

    private static func configureLocalIdentity(
        _ securityOptions: sec_protocol_options_t,
        identity: sec_identity_t,
        minimumTLSVersion: tls_protocol_version_t
    ) {
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, minimumTLSVersion)
        sec_protocol_options_set_local_identity(securityOptions, identity)
    }

    private static func configurePinnedCertificateVerification(
        _ securityOptions: sec_protocol_options_t,
        pinnedCertificateData: Data,
        minimumTLSVersion: tls_protocol_version_t
    ) {
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, minimumTLSVersion)
        sec_protocol_options_set_verify_block(
            securityOptions,
            { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let certificateChain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate]
                guard let certificate = certificateChain?.first else {
                    complete(false)
                    return
                }

                let certificateData = SecCertificateCopyData(certificate) as Data
                complete(certificateData == pinnedCertificateData)
            },
            DispatchQueue.global(qos: .userInitiated)
        )
    }

    private static func bundledCertificateData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: Resource.certificateName,
            withExtension: Resource.certificateExtension
        ) else {
            throw NSError(domain: "transport.tls", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing bundled certificate resource"
            ])
        }

        return try Data(contentsOf: url)
    }

    private static func bundledLocalIdentity() throws -> sec_identity_t {
        guard let url = Bundle.module.url(
            forResource: Resource.certificateName,
            withExtension: Resource.identityExtension
        ) else {
            throw NSError(domain: "transport.tls", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Missing bundled identity resource"
            ])
        }

        let identityData = try Data(contentsOf: url)
        let options = [
            kSecImportExportPassphrase as String: Resource.identityPassword
        ] as CFDictionary

        var importedItems: CFArray?
        let status = SecPKCS12Import(identityData as CFData, options, &importedItems)
        guard status == errSecSuccess,
              let items = importedItems as? [[String: Any]],
              let firstItem = items.first,
              let secIdentity = firstItem[kSecImportItemIdentity as String] as! SecIdentity?,
              let identity = sec_identity_create(secIdentity) else {
            throw NSError(domain: "transport.tls", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Failed to import bundled PKCS#12 identity"
            ])
        }

        return identity
    }
}
