import Foundation
import Testing
@testable import Transport

@Suite("FramePacket Tests")
struct FramePacketTests {
    @Test
    func packetizedPrependsBigEndianLengthHeader() {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let packet = FramePacket.packetized(payload)

        #expect(packet.count == 8)
        #expect(packet.prefix(4) == Data([0x00, 0x00, 0x00, 0x04]))
        #expect(packet.dropFirst(4) == payload)
    }
}
