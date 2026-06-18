import CryptoKit
import Foundation
import Network

public enum TransportTLSParameters {
    nonisolated public static func makePreSharedKeyParameters(
        passcode: String,
        serviceLabel: String,
        minimumTLSVersion: tls_protocol_version_t = .TLSv12
    ) -> NWParameters {
        .init(tls: Self.tlsOptions(passcode: passcode,
                                   serviceLabel: serviceLabel,
                                   minimumTLSVersion: minimumTLSVersion))
    }
    
    private static func tlsOptions(passcode: String,
                                   serviceLabel: String,
                                   minimumTLSVersion: tls_protocol_version_t) -> NWProtocolTLS.Options? {
        
        guard let serviceLabelData = serviceLabel.data(using: .utf8),
              let passwordData = passcode.data(using: .utf8) else {
            return nil
        }
        
        guard let cipherSuite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) else {
            return nil
        }
        
        let tlsOptions = NWProtocolTLS.Options()
        let securityOptions = tlsOptions.securityProtocolOptions
        
        let authenticationKey = SymmetricKey(data: passwordData) // SymmetricKey(size: .bits128)
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: serviceLabelData,
            using: authenticationKey
        )
        let pskData = authenticationCode.withUnsafeBytes { DispatchData(bytes: $0) }
        let pskIdentityData = serviceLabelData.withUnsafeBytes { DispatchData(bytes: $0) }

        sec_protocol_options_add_pre_shared_key(
            securityOptions,
            pskData as dispatch_data_t,
            pskIdentityData as dispatch_data_t
        )

        sec_protocol_options_set_min_tls_protocol_version(securityOptions, minimumTLSVersion)
        sec_protocol_options_append_tls_ciphersuite(
            securityOptions,
            cipherSuite
        )
        
        return tlsOptions
    }
}
