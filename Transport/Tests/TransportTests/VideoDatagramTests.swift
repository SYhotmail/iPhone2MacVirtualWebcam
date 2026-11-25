import Foundation
import Testing
@testable import Transport

@Suite("Video Datagram Tests")
struct VideoDatagramTests {
    @Test
    func chunksRoundTripThroughParse() throws {
        let frame = Data((0..<250).map { UInt8($0 % 256) })
        let chunks = VideoDatagram.chunks(of: frame, frameID: 0xA1B2C3D4, isKeyframe: true, maximumDatagramSize: 110)

        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count <= 110 })
        var rebuilt = Data()
        for (index, chunk) in chunks.enumerated() {
            let (header, payload) = try #require(VideoDatagram.parse(chunk))
            #expect(header == .init(frameID: 0xA1B2C3D4, chunkIndex: UInt16(index), chunkCount: 3, isKeyframe: true))
            rebuilt.append(payload)
        }
        #expect(rebuilt == frame)
    }

    @Test
    func chunksRejectUnusableSizes() {
        #expect(VideoDatagram.chunks(of: Data(), frameID: 1, isKeyframe: false, maximumDatagramSize: 1200).isEmpty)
        #expect(VideoDatagram.chunks(of: Data([1]), frameID: 1, isKeyframe: false, maximumDatagramSize: 10).isEmpty)
    }

    @Test
    func parseRejectsMalformedDatagrams() {
        var badVersion = VideoDatagram.chunks(of: Data([1, 2]), frameID: 1, isKeyframe: false, maximumDatagramSize: 100)[0]
        badVersion[0] = 99
        var badIndex = VideoDatagram.chunks(of: Data([1, 2]), frameID: 1, isKeyframe: false, maximumDatagramSize: 100)[0]
        badIndex[7] = 5 // chunkIndex 5 of 1

        #expect(VideoDatagram.parse(Data(repeating: 1, count: 10)) == nil)
        #expect(VideoDatagram.parse(badVersion) == nil)
        #expect(VideoDatagram.parse(badIndex) == nil)
    }

    @Test
    func reassemblesOutOfOrderChunks() {
        var reassembler = FrameReassembler()
        let frame = Data(repeating: 7, count: 300)
        let chunks = datagrams(frame, id: 0, keyframe: true)

        #expect(reassembler.add(chunks[2]) == .none)
        #expect(reassembler.add(chunks[0]) == .none)
        #expect(reassembler.add(chunks[0]) == .none) // duplicate
        #expect(reassembler.add(chunks[1]) == .frame(frame))
    }

    @Test
    func dropsDeltaFramesUntilFirstKeyframe() {
        var reassembler = FrameReassembler()

        #expect(reassembler.add(datagrams(Data([1]), id: 0, keyframe: false)[0]) == .needsKeyframe)
        #expect(reassembler.add(datagrams(Data([2]), id: 1, keyframe: false)[0]) == .needsKeyframe)
        #expect(reassembler.add(datagrams(Data([3]), id: 2, keyframe: true)[0]) == .frame(Data([3])))
        #expect(reassembler.add(datagrams(Data([4]), id: 3, keyframe: false)[0]) == .frame(Data([4])))
    }

    @Test
    func lostFrameStopsDeltaFramesUntilNextKeyframe() {
        var reassembler = FrameReassembler()
        _ = reassembler.add(datagrams(Data([1]), id: 10, keyframe: true)[0])

        // Frame 11 never arrives.
        #expect(reassembler.add(datagrams(Data([3]), id: 12, keyframe: false)[0]) == .needsKeyframe)
        #expect(reassembler.add(datagrams(Data([4]), id: 13, keyframe: false)[0]) == .needsKeyframe)
        #expect(reassembler.add(datagrams(Data([5]), id: 14, keyframe: true)[0]) == .frame(Data([5])))
        #expect(reassembler.add(datagrams(Data([6]), id: 15, keyframe: false)[0]) == .frame(Data([6])))
    }

    @Test
    func incompleteFrameIsAbandonedWhenNewerFrameCompletes() {
        var reassembler = FrameReassembler()
        _ = reassembler.add(datagrams(Data([1]), id: 0, keyframe: true)[0])
        let partial = datagrams(Data(repeating: 2, count: 300), id: 1, keyframe: false)

        #expect(reassembler.add(partial[0]) == .none)
        #expect(reassembler.add(datagrams(Data([3]), id: 2, keyframe: false)[0]) == .needsKeyframe)
        // The late rest of frame 1 is stale now.
        #expect(reassembler.add(partial[1]) == .none)
        #expect(reassembler.add(partial[2]) == .none)
    }

    @Test
    func ignoresFramesOlderThanLastDelivered() {
        var reassembler = FrameReassembler()
        _ = reassembler.add(datagrams(Data([1]), id: 5, keyframe: true)[0])

        #expect(reassembler.add(datagrams(Data([0]), id: 4, keyframe: true)[0]) == .none)
        #expect(reassembler.add(datagrams(Data([1]), id: 5, keyframe: true)[0]) == .none)
    }

    @Test
    func frameIDsWrapAround() {
        var reassembler = FrameReassembler()

        #expect(reassembler.add(datagrams(Data([1]), id: .max, keyframe: true)[0]) == .frame(Data([1])))
        #expect(reassembler.add(datagrams(Data([2]), id: 0, keyframe: false)[0]) == .frame(Data([2])))
        #expect(FrameReassembler.isNewer(0, than: .max))
        #expect(!FrameReassembler.isNewer(.max, than: 0))
    }

    @Test
    func dropsFramesLargerThanLimit() {
        var reassembler = FrameReassembler(maximumFrameByteCount: 150)
        let chunks = datagrams(Data(repeating: 1, count: 300), id: 0, keyframe: true)

        #expect(chunks.map { reassembler.add($0) } == [.none, .none, .none])
    }

    private func datagrams(_ frame: Data, id: UInt32, keyframe: Bool) -> [Data] {
        VideoDatagram.chunks(of: frame, frameID: id, isKeyframe: keyframe, maximumDatagramSize: 110)
    }
}
