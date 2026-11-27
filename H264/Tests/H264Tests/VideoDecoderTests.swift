import CoreGraphics
import Foundation
import Testing
@_spi(Testing) import H264

@Suite("Video Decoder Tests")
struct VideoDecoderTests {
    @Test
    func splitAnnexBNALUnitsReturnsEachStartCodeDelimitedNAL() {
        let accessUnit = Data([
            0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1F,
            0, 0, 0, 1, 0x68, 0xEE, 0x3C, 0x80,
            0, 0, 0, 1, 0x65, 0x88, 0x84, 0x21,
        ])

        let nalUnits = VideoDecoder.splitAnnexBNALUnits(in: accessUnit)

        #expect(nalUnits.count == 3)
        #expect(nalUnits[0] == Data([0, 0, 0, 1, 0x67, 0x64, 0x00, 0x1F]))
        #expect(nalUnits[1] == Data([0, 0, 0, 1, 0x68, 0xEE, 0x3C, 0x80]))
        #expect(nalUnits[2] == Data([0, 0, 0, 1, 0x65, 0x88, 0x84, 0x21]))
    }

    @Test
    func splitAnnexBNALUnitsSkipsIncompleteSegments() {
        let accessUnit = Data([
            0, 0, 0, 1,
            0, 0, 0, 1, 0x65, 0xAA,
        ])

        let nalUnits = VideoDecoder.splitAnnexBNALUnits(in: accessUnit)

        #expect(nalUnits.count == 1)
        #expect(nalUnits[0] == Data([0, 0, 0, 1, 0x65, 0xAA]))
    }

    @Test
    func splitAnnexBNALUnitsReturnsEmptyForDataWithoutStartCodes() {
        let accessUnit = Data([0x67, 0x64, 0x00, 0x1F, 0x68, 0xEE, 0x3C, 0x80])

        let nalUnits = VideoDecoder.splitAnnexBNALUnits(in: accessUnit)

        #expect(nalUnits.isEmpty)
    }
}
