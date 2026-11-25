import Foundation

/// Wire format for video frames sent as QUIC datagrams.
///
/// A frame is split into chunks that each fit one datagram. Every chunk starts with a
/// 10-byte big-endian header:
///
///     version: UInt8 | flags: UInt8 | frameID: UInt32 | chunkIndex: UInt16 | chunkCount: UInt16
///
/// Datagrams can be lost or reordered; `FrameReassembler` rebuilds whole frames and drops
/// the rest.
enum VideoDatagram {
    static let version: UInt8 = 1
    static let headerByteCount = 10
    /// Used when the connection doesn't report a usable datagram size. Fits any IPv6 path.
    static let fallbackMaximumDatagramSize = 1200

    struct Header: Equatable {
        var frameID: UInt32
        var chunkIndex: UInt16
        var chunkCount: UInt16
        var isKeyframe: Bool
    }

    private static let keyframeFlag: UInt8 = 1 << 0

    /// Splits `frame` into datagrams no larger than `maximumDatagramSize`.
    ///
    /// Returns an empty array when the frame is empty, a datagram can't hold any payload, or the
    /// frame would need more than `UInt16.max` chunks.
    static func chunks(of frame: Data, frameID: UInt32, isKeyframe: Bool, maximumDatagramSize: Int) -> [Data] {
        let payloadCapacity = maximumDatagramSize - headerByteCount
        guard !frame.isEmpty, payloadCapacity > 0 else {
            return []
        }
        let chunkCount = (frame.count + payloadCapacity - 1) / payloadCapacity
        guard chunkCount <= Int(UInt16.max) else {
            return []
        }

        return (0..<chunkCount).map { index in
            let start = frame.startIndex + index * payloadCapacity
            let end = min(start + payloadCapacity, frame.endIndex)
            var datagram = Data(capacity: headerByteCount + (end - start))
            datagram.append(version)
            datagram.append(isKeyframe ? keyframeFlag : 0)
            datagram.appendBigEndian(frameID)
            datagram.appendBigEndian(UInt16(index))
            datagram.appendBigEndian(UInt16(chunkCount))
            datagram.append(frame[start..<end])
            return datagram
        }
    }

    /// Parses one datagram; `nil` for unknown versions or malformed headers.
    static func parse(_ datagram: Data) -> (header: Header, payload: Data)? {
        guard datagram.count > headerByteCount else {
            return nil
        }
        let bytes = [UInt8](datagram.prefix(headerByteCount))
        guard bytes[0] == version else {
            return nil
        }
        let header = Header(
            frameID: UInt32(bytes[2]) << 24 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 8 | UInt32(bytes[5]),
            chunkIndex: UInt16(bytes[6]) << 8 | UInt16(bytes[7]),
            chunkCount: UInt16(bytes[8]) << 8 | UInt16(bytes[9]),
            isKeyframe: bytes[1] & keyframeFlag != 0
        )
        guard header.chunkCount > 0, header.chunkIndex < header.chunkCount else {
            return nil
        }
        return (header, datagram.dropFirst(headerByteCount))
    }
}

/// Rebuilds frames from `VideoDatagram` chunks, delivering only frames the decoder can use.
///
/// Frames are delivered in frame-ID order. After any loss (a missing frame or one that never
/// completed) it drops frames until the next keyframe, so the decoder never sees a frame whose
/// reference is missing.
struct FrameReassembler {
    enum Event: Equatable {
        /// Nothing to deliver yet.
        case none
        /// A complete frame the decoder can use.
        case frame(Data)
        /// A frame was dropped because an earlier one was lost; the sender should send a keyframe.
        case needsKeyframe
    }

    private struct PartialFrame {
        let chunkCount: Int
        let isKeyframe: Bool
        var chunks: [Data?]
        var receivedCount = 0
        var byteCount = 0
    }

    /// Upper bound on one reassembled frame, so a broken sender can't exhaust memory.
    let maximumFrameByteCount: Int
    /// Frames being reassembled at once; the oldest is abandoned beyond this.
    let maximumPendingFrames: Int

    private var pending = [UInt32: PartialFrame]()
    private var lastFrameID: UInt32?
    private var awaitingKeyframe = true

    init(maximumFrameByteCount: Int = 8 * 1024 * 1024, maximumPendingFrames: Int = 8) {
        self.maximumFrameByteCount = maximumFrameByteCount
        self.maximumPendingFrames = maximumPendingFrames
    }

    mutating func add(_ datagram: Data) -> Event {
        guard let (header, payload) = VideoDatagram.parse(datagram) else {
            return .none
        }
        let frameID = header.frameID
        if let lastFrameID, !Self.isNewer(frameID, than: lastFrameID) {
            return .none
        }

        var frame = pending[frameID] ?? PartialFrame(
            chunkCount: Int(header.chunkCount),
            isKeyframe: header.isKeyframe,
            chunks: Array(repeating: nil, count: Int(header.chunkCount))
        )
        let index = Int(header.chunkIndex)
        guard frame.chunkCount == Int(header.chunkCount), frame.chunks[index] == nil else {
            return .none
        }
        guard frame.byteCount + payload.count <= maximumFrameByteCount else {
            pending[frameID] = nil
            return .none
        }
        frame.chunks[index] = payload
        frame.receivedCount += 1
        frame.byteCount += payload.count

        guard frame.receivedCount == frame.chunkCount else {
            pending[frameID] = frame
            evictOldestIfNeeded()
            return .none
        }
        return complete(frame, frameID: frameID)
    }

    private mutating func complete(_ frame: PartialFrame, frameID: UInt32) -> Event {
        let followsPrevious = lastFrameID.map { frameID == $0 &+ 1 } ?? false
        lastFrameID = frameID
        // Anything older still pending can no longer be delivered in order.
        pending = pending.filter { Self.isNewer($0.key, than: frameID) }

        guard frame.isKeyframe || (followsPrevious && !awaitingKeyframe) else {
            awaitingKeyframe = true
            return .needsKeyframe
        }
        awaitingKeyframe = false
        var data = Data(capacity: frame.byteCount)
        frame.chunks.forEach { data.append($0!) }
        return .frame(data)
    }

    private mutating func evictOldestIfNeeded() {
        guard pending.count > maximumPendingFrames,
              let oldest = pending.keys.min(by: { Self.isNewer($1, than: $0) }) else {
            return
        }
        pending[oldest] = nil
    }

    /// Frame IDs wrap around; `a` is newer when it is less than half the ID space ahead of `b`.
    static func isNewer(_ a: UInt32, than b: UInt32) -> Bool {
        Int32(bitPattern: a &- b) > 0
    }
}

/// Messages the receiver sends back to the sender on the control stream after pairing.
enum StreamControlMessage: UInt8 {
    /// The receiver lost a frame and needs a keyframe to recover.
    case keyframeRequest = 1
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
