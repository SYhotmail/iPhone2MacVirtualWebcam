//
//  MacIdentityStore.swift
//  Cam2Mac
//

import Foundation
import Security
import Transport

/// The receiver's own TLS identity: a P-256 key and self-signed certificate kept in the Keychain.
///
/// Created once per Mac; paired iPhones pin `fingerprint`.
nonisolated struct MacIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let fingerprint: Data
}

nonisolated enum MacIdentityStore {
    private static let label = "Cam2Mac Receiver Identity"
    private static let keyTag = Data("by.sy.cam2mac.receiver.identity-key".utf8)

    static func loadOrCreate(commonName: String) throws -> MacIdentity {
        if let existing = try loadExisting() {
            return existing
        }
        // Never bulk-delete here: the macOS file-based keychain can ignore unsupported
        // query attributes in SecItemDelete. A key left by an interrupted run is harmless.
        try create(commonName: commonName)
        guard let created = try loadExisting() else {
            throw error("Created receiver identity could not be loaded", status: errSecItemNotFound)
        }
        return created
    }

    private static func loadExisting() throws -> MacIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let result, CFGetTypeID(result) == SecIdentityGetTypeID() else {
            throw error("Failed to read receiver identity", status: status)
        }

        let identity = result as! SecIdentity
        var certificate: SecCertificate?
        let certificateStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard certificateStatus == errSecSuccess, let certificate else {
            throw error("Receiver identity has no certificate", status: certificateStatus)
        }
        let der = SecCertificateCopyData(certificate) as Data
        return MacIdentity(identity: identity, fingerprint: FrameStreamService.fingerprint(ofCertificate: der))
    }

    private static func create(commonName: String) throws {
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrLabel as String: label,
            ] as [String: Any],
        ]
        var keyError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &keyError) else {
            throw keyError!.takeRetainedValue()
        }

        let der = try SelfSignedCertificate.make(commonName: commonName, privateKey: privateKey)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw error("Generated certificate is invalid", status: errSecDecode)
        }

        let addStatus = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label,
        ] as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw error("Failed to store receiver certificate", status: addStatus)
        }
    }

    private static func error(_ message: String, status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
