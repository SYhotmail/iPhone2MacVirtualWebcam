import Foundation
import Security

/// Builds a minimal self-signed X.509 v3 certificate for a P-256 key.
///
/// The certificate is only used as a TLS identity whose SHA-256 fingerprint the
/// iPhone pins after pairing, so it carries no extensions.
public enum SelfSignedCertificate {
    public enum BuildError: Error {
        case missingPublicKey
        case publicKeyExport(Error?)
        case signing(Error?)
    }

    public static func make(
        commonName: String,
        privateKey: SecKey,
        notBefore: Date = Date(),
        validity: TimeInterval = 20 * 365 * 24 * 60 * 60
    ) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw BuildError.missingPublicKey
        }
        var exportError: Unmanaged<CFError>?
        guard let publicKeyBytes = SecKeyCopyExternalRepresentation(publicKey, &exportError) as Data? else {
            throw BuildError.publicKeyExport(exportError?.takeRetainedValue())
        }

        let signatureAlgorithm = DER.sequence(OID.ecdsaWithSHA256)
        let name = DER.sequence(DER.set(DER.sequence(OID.commonName + DER.utf8String(commonName))))
        let subjectPublicKeyInfo = DER.sequence(
            DER.sequence(OID.ecPublicKey + OID.prime256v1) + DER.bitString(publicKeyBytes)
        )
        let tbs = DER.sequence(
            DER.explicit(0, DER.integer(Data([0x02])))      // v3
            + DER.integer(randomSerialNumber())
            + signatureAlgorithm
            + name                                          // issuer
            + DER.sequence(DER.utcTime(notBefore) + DER.utcTime(notBefore.addingTimeInterval(validity)))
            + name                                          // subject
            + subjectPublicKeyInfo
        )

        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbs as CFData,
            &signError
        ) as Data? else {
            throw BuildError.signing(signError?.takeRetainedValue())
        }

        return DER.sequence(tbs + signatureAlgorithm + DER.bitString(signature))
    }

    private static func randomSerialNumber() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] = (bytes[0] & 0x7F) | 0x01 // positive and non-zero
        return Data(bytes)
    }
}

private enum OID {
    static let ecdsaWithSHA256 = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
    static let ecPublicKey = Data([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
    static let prime256v1 = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
    static let commonName = Data([0x06, 0x03, 0x55, 0x04, 0x03])
}

private enum DER {
    static func sequence(_ content: Data) -> Data { element(0x30, content) }
    static func set(_ content: Data) -> Data { element(0x31, content) }
    static func integer(_ bytes: Data) -> Data { element(0x02, bytes) }
    static func utf8String(_ value: String) -> Data { element(0x0C, Data(value.utf8)) }
    static func bitString(_ bytes: Data) -> Data { element(0x03, Data([0x00]) + bytes) }
    static func explicit(_ tag: UInt8, _ content: Data) -> Data { element(0xA0 | tag, content) }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return element(0x17, Data(formatter.string(from: date).utf8))
    }

    static func element(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        let length = content.count
        if length < 0x80 {
            result.append(UInt8(length))
        } else {
            var lengthBytes = [UInt8]()
            var remaining = length
            while remaining > 0 {
                lengthBytes.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
            result.append(0x80 | UInt8(lengthBytes.count))
            result.append(contentsOf: lengthBytes)
        }
        result.append(content)
        return result
    }
}
