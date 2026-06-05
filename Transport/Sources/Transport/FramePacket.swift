import Foundation

enum FramePacket {
    static let headerByteCount = 4
    
    static func packetSize(for chunk: Data) -> Int {
        let res = chunk.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        return Int(res)
    }

    static func packetized(_ payload: Data) -> Data {
        var size = UInt32(payload.count).bigEndian
        var packet = Data()
        packet.reserveCapacity(headerByteCount + payload.count)
        withUnsafeBytes(of: &size) { headerBuffer in
            packet.append(contentsOf: headerBuffer)
        }
        packet.append(payload)
        return packet
    }
}
