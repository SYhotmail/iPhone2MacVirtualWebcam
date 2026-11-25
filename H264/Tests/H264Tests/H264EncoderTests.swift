//
//  H264EncoderTests.swift
//  H264
//
//  Created by Siarhei Yakushevich on 04/06/2026.
//

import AVFoundation
import Combine
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

@Suite("H264 Encoder Ordering Tests")
struct H264EncoderOrderingTests {
    /// Simulates a rotation: a burst of landscape frames followed by portrait frames.
    /// Output must keep submission order so the decoder never sees new-size frames
    /// before the new parameter sets, or old-size frames after them.
    @Test
    func sizeChangeKeepsFrameOrderThroughDecode() async throws {
        let packets = PacketCollector()
        let encoder = H264Encoder(expectedFrameRate: 30, maxKeyInterval: 30) { packet, isKeyframe in packets.append(packet, isKeyframe: isKeyframe) }
        let landscape = try makePixelBuffer(width: 320, height: 240)
        let portrait = try makePixelBuffer(width: 240, height: 320)

        let rotations = 20
        let framesPerOrientation = 5
        for rotation in 0..<rotations {
            let buffer = rotation.isMultiple(of: 2) ? landscape : portrait
            for _ in 0..<framesPerOrientation { encoder.scheduleToEncode(imageBuffer: buffer) }
        }
        let expectedCount = rotations * framesPerOrientation
        encoder.scheduleToInvalidate()
        await waitUntil { packets.count >= expectedCount }

        let decoder = H264Decoder()
        let sizes = SizeCollector()
        let subscription = decoder.publisher.sink { buffer in
            guard let format = CMSampleBufferGetFormatDescription(buffer.value) else { return }
            sizes.append(CMVideoFormatDescriptionGetDimensions(format))
        }
        defer { subscription.cancel() }
        for packet in packets.snapshot() {
            decoder.scheduleToDecode(packet)
        }
        await waitUntil { sizes.count >= expectedCount }

        let expectedWidths = (0..<rotations).flatMap { rotation in
            Array(repeating: Int32(rotation.isMultiple(of: 2) ? 320 : 240), count: framesPerOrientation)
        }
        #expect(sizes.snapshot().map(\.width) == expectedWidths)
    }

    @Test
    func forcedKeyframeIsFlaggedAndSentWithParameterSets() async throws {
        let packets = PacketCollector()
        let encoder = H264Encoder(expectedFrameRate: 30, maxKeyInterval: 30) { packet, isKeyframe in packets.append(packet, isKeyframe: isKeyframe) }
        let buffer = try makePixelBuffer(width: 320, height: 240)

        for _ in 0..<3 { encoder.scheduleToEncode(imageBuffer: buffer) }
        encoder.scheduleToForceKeyframe()
        for _ in 0..<2 { encoder.scheduleToEncode(imageBuffer: buffer) }
        await waitUntil { packets.count >= 5 }

        #expect(packets.keyframeFlags() == [true, false, false, true, false])
        // Keyframes lead with an SPS NAL unit (type 7) so the receiver can resume from them.
        let startsWithSPS = packets.snapshot().map { $0.count > 4 && $0.starts(with: [0, 0, 0, 1]) && $0[4] & 0x1F == 7 }
        #expect(startsWithSPS == [true, false, false, true, false])
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &buffer)
        return try #require(status == kCVReturnSuccess ? buffer : nil)
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class PacketCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var packets = [Data]()
    private var flags = [Bool]()
    func append(_ packet: Data, isKeyframe: Bool) { lock.withLock { packets.append(packet); flags.append(isKeyframe) } }
    var count: Int { lock.withLock { packets.count } }
    func snapshot() -> [Data] { lock.withLock { packets } }
    func keyframeFlags() -> [Bool] { lock.withLock { flags } }
}

private final class SizeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes = [CMVideoDimensions]()
    func append(_ size: CMVideoDimensions) { lock.withLock { sizes.append(size) } }
    var count: Int { lock.withLock { sizes.count } }
    func snapshot() -> [CMVideoDimensions] { lock.withLock { sizes } }
}
