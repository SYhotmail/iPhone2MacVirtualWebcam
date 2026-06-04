//
//  H264EncoderTests.swift
//  H264
//
//  Created by Siarhei Yakushevich on 04/06/2026.
//

import CoreGraphics
import Foundation
import Testing
@_spi(Testing) import H264

@Suite("H264 Encoder Tests")
struct H264EncoderTests {
    @Test
    func targetBitRateUsesExpectedRanges() {
        #expect(H264Encoder.targetBitRate(size: CGSize(width: 320, height: 240)) == 1_000_000)
        #expect(H264Encoder.targetBitRate(size: CGSize(width: 1280, height: 720)) == 4_000_000)
        #expect(H264Encoder.targetBitRate(size: CGSize(width: 2560, height: 1440)) == 6_000_000)
    }
}
