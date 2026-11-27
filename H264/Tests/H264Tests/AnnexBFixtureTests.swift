import Foundation
@_spi(Testing) import H264
import Testing

/// Checks the Mac's Annex-B splitter against `ProtocolFixtures/annexb-start-codes.json`,
/// whose `normalizedHex` is what the Android sender produces (checked by its own tests).
@Suite("Annex-B fixtures")
struct AnnexBFixtureTests {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            var name: String
            var normalizedHex: String
            var nalUnitsHex: [String]
        }

        var cases: [Case]
    }

    @Test
    func splitsNormalizedAccessUnitsIntoFixtureNALUnits() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // H264Tests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // H264
            .deletingLastPathComponent() // repository root
        let data = try Data(contentsOf: root.appending(path: "ProtocolFixtures/annexb-start-codes.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        #expect(!fixture.cases.isEmpty)

        for testCase in fixture.cases {
            let accessUnit = try #require(hexData(testCase.normalizedHex))
            let expected = try testCase.nalUnitsHex.map { try #require(hexData($0)) }
            #expect(VideoDecoder.splitAnnexBNALUnits(in: accessUnit) == expected, "\(testCase.name)")
        }
    }

    private func hexData(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
