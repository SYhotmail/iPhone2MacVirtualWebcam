import Foundation
import Network
import Security
import Transport


nonisolated struct ServerTLSConfiguration: Sendable {
    nonisolated struct IdentityConfiguration: Sendable {
        let resourceName: String
        let resourceExtension: String
        let password: String

        init(resourceName: String, resourceExtension: String = "p12", password: String) {
            self.resourceName = resourceName
            self.resourceExtension = resourceExtension
            self.password = password
        }
        
        static let `default` = Self.init(resourceName: "cam2mac-server", password: "cam2mac-dev")
        
    }

    static let `default` = Self.init(identity: .default)

    let identity: IdentityConfiguration
    let minimumTLSVersion: tls_protocol_version_t

    init(
        identity: IdentityConfiguration,
        minimumTLSVersion: tls_protocol_version_t = .TLSv13
    ) {
        self.identity = identity
        self.minimumTLSVersion = minimumTLSVersion
    }

    func makeParameters(bundle: Bundle) throws -> NWParameters {
        let serverIdentity = try loadIdentity(bundle: bundle)
        return TransportTLSParameters.makeServerParameters(
            identity: serverIdentity,
            minimumTLSVersion: minimumTLSVersion
        )
    }

    private func loadIdentity(bundle: Bundle) throws -> sec_identity_t {
        guard
            let url = bundle.url(
                forResource: identity.resourceName,
                withExtension: identity.resourceExtension,
                subdirectory: "Resources"
            ) ?? bundle.url(
                forResource: identity.resourceName,
                withExtension: identity.resourceExtension
            )
        else {
            throw ServerTLSConfigurationError.missingServerIdentity
        }

        let pkcs12Data = try Data(contentsOf: url) as CFData
        let options = [kSecImportExportPassphrase as String: identity.password] as CFDictionary
        var items: CFArray?
        let status = SecPKCS12Import(pkcs12Data, options, &items)

        guard status == errSecSuccess else {
            throw ServerTLSConfigurationError.failedToImportIdentity(status)
        }

        let importedItems = items as? [[String: Any]]
        guard
            let firstItem = importedItems?.first,
            let serverIdentity = firstItem[kSecImportItemIdentity as String] as! SecIdentity?
        else {
            throw ServerTLSConfigurationError.missingServerIdentity
        }

        return unsafeBitCast(serverIdentity, to: sec_identity_t.self)
    }
}

enum ServerTLSConfigurationError: LocalizedError {
    case missingServerIdentity
    case failedToImportIdentity(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingServerIdentity:
            return "Missing bundled TLS server identity."
        case .failedToImportIdentity(let status):
            return "Failed to import bundled TLS server identity (\(status))."
        }
    }
}
