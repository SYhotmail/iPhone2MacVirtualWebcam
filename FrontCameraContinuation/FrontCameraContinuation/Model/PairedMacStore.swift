//
//  PairedMacStore.swift
//  FrontCameraContinuation
//

import Foundation
import Security
import Transport

/// The Mac this iPhone is paired with and the credentials it registered there.
nonisolated struct PairedMac: Codable, Sendable, Equatable {
    /// Bonjour service name the Mac advertises.
    let serviceName: String
    /// SHA-256 of the Mac's certificate.
    let fingerprint: Data
    let clientID: UUID
    let secret: Data

    /// New credentials for pairing with the Mac described by `invitation`.
    init(invitation: PairingInvitation) {
        var secret = Data(count: 32)
        _ = secret.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        self.serviceName = invitation.serviceName
        self.fingerprint = invitation.fingerprint
        self.clientID = UUID()
        self.secret = secret
    }

    var hello: PairingHello {
        .hello(clientID: clientID, secret: secret)
    }
}

/// Keychain persistence for the single paired Mac.
nonisolated enum PairedMacStore {
    private static var baseQuery: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "by.sy.cam2mac.paired-mac",
        kSecAttrAccount as String: "receiver",
    ] }

    static func load() -> PairedMac? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    @discardableResult
    static func save(_ pairedMac: PairedMac) -> Bool {
        guard let data = try? JSONEncoder().encode(pairedMac) else {
            return false
        }
        remove()
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func remove() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
