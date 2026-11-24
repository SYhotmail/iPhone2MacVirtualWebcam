import Foundation

enum FramePacket {
    static let headerByteCount = 4

    static func payloadSize(for header: Data) -> Int {
        let res = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
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

    /// Reads one length-prefixed packet, accumulating partial reads until the full header and payload arrive.
    static func read(
        from connection: any TransportConnection,
        maximumPayloadSize: Int = .max
    ) async throws -> Data {
        let header = try await readExactByteCount(headerByteCount, from: connection)
        let expectedSize = payloadSize(for: header)
        guard expectedSize <= maximumPayloadSize else {
            throw NSError(
                domain: "frame-packet",
                code: Int(POSIXErrorCode.EMSGSIZE.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "Packet of \(expectedSize) bytes exceeds limit \(maximumPayloadSize)"]
            )
        }
        return try await readExactByteCount(expectedSize, from: connection)
    }

    private static func readExactByteCount(_ expectedSize: Int, from connection: any TransportConnection) async throws -> Data {
        var accumulated = Data()
        accumulated.reserveCapacity(expectedSize)

        while accumulated.count < expectedSize {
            let remaining = expectedSize - accumulated.count
            let result = try await connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: remaining
            )

            if !result.data.isEmpty {
                accumulated.append(result.data)
            }

            if result.isComplete && accumulated.count < expectedSize {
                throw NSError(
                    domain: "frame-packet",
                    code: Int(POSIXErrorCode.ENOTCONN.rawValue),
                    userInfo: [NSLocalizedDescriptionKey: "Stream ended before \(expectedSize) bytes were received"]
                )
            }
        }

        return accumulated
    }
}
