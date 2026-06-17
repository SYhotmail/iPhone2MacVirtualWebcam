import CryptoKit
import Foundation
import Network
import Security

public enum TransportTLSParameters {
    nonisolated public static func makeClientParameters(
        pinnedServerPublicKeyHashBase64: String,
        minimumTLSVersion: tls_protocol_version_t = .TLSv13
    ) throws -> NWParameters {
        guard let pinnedHash = Data(base64Encoded: pinnedServerPublicKeyHashBase64) else {
            throw TransportTLSError.invalidPinnedPublicKeyHash
        }

        let tlsOptions = NWProtocolTLS.Options()
        let securityOptions = tlsOptions.securityProtocolOptions

        sec_protocol_options_set_min_tls_protocol_version(securityOptions, minimumTLSVersion)
        sec_protocol_options_set_verify_block(securityOptions, { _, trust, complete in
            complete(pinnedPublicKey(for: trust) == pinnedHash)
        }, DispatchQueue.global(qos: .userInitiated))

        return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    }

    nonisolated public static func makeServerParameters(
        identity: sec_identity_t,
        minimumTLSVersion: tls_protocol_version_t = .TLSv13
    ) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        let securityOptions = tlsOptions.securityProtocolOptions

        sec_protocol_options_set_min_tls_protocol_version(securityOptions, minimumTLSVersion)
        sec_protocol_options_set_local_identity(securityOptions, identity)

        return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    }

    nonisolated private static func pinnedPublicKey(for trust: sec_trust_t) -> Data? {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        let certificateChain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate]
        guard
            let certificate = certificateChain?.first,
            let publicKey = SecCertificateCopyKey(certificate),
            let subjectPublicKeyInfo = subjectPublicKeyInfo(for: publicKey)
        else {
            return nil
        }

        let actualHash = Data(SHA256.hash(data: subjectPublicKeyInfo))
        return actualHash
    }

    nonisolated private static func subjectPublicKeyInfo(for key: SecKey) -> Data? {
        guard
            let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data?,
            let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
            let keyType = attributes[kSecAttrKeyType] as! CFString?
        else {
            return nil
        }

        let algorithmIdentifier: [UInt8]
        switch keyType {
        case kSecAttrKeyTypeECSECPrimeRandom:
            algorithmIdentifier = [
                0x30, 0x13,
                0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
            ]
        case kSecAttrKeyTypeRSA:
            algorithmIdentifier = [
                0x30, 0x0D,
                0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
                0x05, 0x00,
            ]
        default:
            return nil
        }

        return wrapSubjectPublicKeyInfo(algorithmIdentifier: algorithmIdentifier, publicKeyBytes: keyData)
    }

    nonisolated private static func wrapSubjectPublicKeyInfo(algorithmIdentifier: [UInt8], publicKeyBytes: Data) -> Data {
        var bitString = Data([0x03])
        bitString.append(derLength(publicKeyBytes.count + 1))
        bitString.append(0x00)
        bitString.append(publicKeyBytes)

        var sequenceBody = Data(algorithmIdentifier)
        sequenceBody.append(bitString)

        var sequence = Data([0x30])
        sequence.append(derLength(sequenceBody.count))
        sequence.append(sequenceBody)
        return sequence
    }

    nonisolated private static func derLength(_ length: Int) -> Data {
        precondition(length >= 0)

        if length < 0x80 {
            return Data([UInt8(length)])
        }

        var value = length
        var octets = [UInt8]()
        while value > 0 {
            octets.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }

        var encoded = Data([0x80 | UInt8(octets.count)])
        encoded.append(contentsOf: octets)
        return encoded
    }
}

public enum TransportTLSError: LocalizedError {
    case invalidPinnedPublicKeyHash

    public var errorDescription: String? {
        switch self {
        case .invalidPinnedPublicKeyHash:
            return "Pinned public key hash must be valid Base64."
        }
    }
}
