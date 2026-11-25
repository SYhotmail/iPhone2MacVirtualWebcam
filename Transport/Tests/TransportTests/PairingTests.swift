import Foundation
import Security
import Testing
@testable import Transport

@Suite("Pairing Tests")
struct PairingTests {
    @Test
    func invitationRoundTripsThroughURL() throws {
        let invitation = PairingInvitation(
            fingerprint: Data((0..<32).map { UInt8($0) }),
            token: Data(repeating: 0xC4, count: 16),
            serviceName: "Studio Mac & Co"
        )

        let parsed = try #require(PairingInvitation(url: invitation.url))

        #expect(parsed == invitation)
        #expect(invitation.url.scheme == "cam2mac")
    }

    @Test(arguments: [
        "https://pair?fp=00&t=00&n=x",
        "cam2mac://pair?fp=zz&t=\(String(repeating: "00", count: 16))&n=Mac",
        "cam2mac://pair?fp=\(String(repeating: "00", count: 31))&t=\(String(repeating: "00", count: 16))&n=Mac",
        "cam2mac://pair?fp=\(String(repeating: "00", count: 32))&t=0011&n=Mac",
        "cam2mac://pair?fp=\(String(repeating: "00", count: 32))&t=\(String(repeating: "00", count: 16))",
    ])
    func invitationRejectsMalformedURLs(_ string: String) throws {
        #expect(PairingInvitation(url: try #require(URL(string: string))) == nil)
    }

    @Test
    func helloUsesCompactWireKeys() throws {
        let hello = PairingHello.hello(clientID: UUID(), secret: Data([1, 2]))
        let json = try #require(String(data: JSONEncoder().encode(hello), encoding: .utf8))

        #expect(json.contains("\"type\":\"hello\""))
        #expect(json.contains("\"v\":1"))
        #expect(try JSONDecoder().decode(PairingHello.self, from: Data(json.utf8)) == hello)
    }

    @Test
    func selfSignedCertificateParsesAndCarriesKeyAndName() throws {
        let privateKey = try makeEphemeralKey()

        let der = try SelfSignedCertificate.make(commonName: "Studio Mac", privateKey: privateKey)
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))

        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "Studio Mac")
        let certificateKey = try #require(SecCertificateCopyKey(certificate))
        let expectedKey = try #require(SecKeyCopyPublicKey(privateKey))
        #expect(SecKeyCopyExternalRepresentation(certificateKey, nil) as Data? == SecKeyCopyExternalRepresentation(expectedKey, nil) as Data?)
    }

    @Test
    func selfSignedCertificateSignatureVerifies() throws {
        let privateKey = try makeEphemeralKey()
        let der = try SelfSignedCertificate.make(commonName: "Mac", privateKey: privateKey)
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))

        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let secTrust = try #require(trust)
        #expect(SecTrustSetAnchorCertificates(secTrust, [certificate] as CFArray) == errSecSuccess)

        var error: CFError?
        #expect(SecTrustEvaluateWithError(secTrust, &error), "\(String(describing: error))")
    }

    @Test
    func pinningAcceptsOnlyMatchingCertificate() throws {
        let pinned = try SelfSignedCertificate.make(commonName: "Mac", privateKey: makeEphemeralKey())
        let other = try SelfSignedCertificate.make(commonName: "Mac", privateKey: makeEphemeralKey())
        let fingerprint = FrameStreamService.fingerprint(ofCertificate: pinned)

        #expect(TransportTLSParameters.leafCertificateMatches(trust: try makeTrust(pinned), pinnedFingerprint: fingerprint))
        #expect(!TransportTLSParameters.leafCertificateMatches(trust: try makeTrust(other), pinnedFingerprint: fingerprint))
    }

    @Test
    func clientAndServerParametersAllowPeerToPeer() throws {
        let privateKey = try makeEphemeralKey()
        let der = try SelfSignedCertificate.make(commonName: "Mac", privateKey: privateKey)
        let client = TransportTLSParameters.makeClientParameters(pinnedFingerprint: FrameStreamService.fingerprint(ofCertificate: der))
        #expect(client.includePeerToPeer)
        #expect(TransportTLSParameters.makeClientParameters(pinnedFingerprint: Data(), transport: .tcp).includePeerToPeer)
        #expect(client.serviceClass == .interactiveVideo)
        #expect(TransportTLSParameters.makeClientParameters(pinnedFingerprint: Data(), transport: .tcp).serviceClass == .interactiveVideo)
    }

    private func makeEphemeralKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }
        return key
    }

    private func makeTrust(_ der: Data) throws -> SecTrust {
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust)
        return try #require(trust)
    }
}
