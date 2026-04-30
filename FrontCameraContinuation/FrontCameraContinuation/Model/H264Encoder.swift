@preconcurrency import AVFoundation
import VideoToolbox
import QuartzCore

final class H264Encoder {
    typealias OutputHandler = (Data) -> Void

    private static let annexBStartCode = [UInt8](arrayLiteral: 0, 0, 0, 1)
    private let expectedFrameRate: Int

    private var compressionSession: VTCompressionSession?
    private var sentConfig = false
    private var frameIndex = 0
    private var encodedWidth: Int32 = 0
    private var encodedHeight: Int32 = 0
    private let maxKeyInterval: Int
    var outputHandler: OutputHandler!

    init(expectedFrameRate: Int = VirtualCameraConfiguration.frameRate,
         maxKeyInterval: Int = VirtualCameraConfiguration.frameRate) {
        assert(expectedFrameRate > 0 && maxKeyInterval > 0)
        self.expectedFrameRate = expectedFrameRate
        self.maxKeyInterval = maxKeyInterval
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let session = compressionSession(for: pixelBuffer) else { return }

        assert(!Thread.isMainThread)
        
        let pts = CMTime(value: CMTimeValue(CACurrentMediaTime() * 1000), timescale: 1000)
        frameIndex += 1
        let shouldForceKeyframe = frameIndex % maxKeyInterval == 0
        let frameProperties: CFDictionary? = shouldForceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    func invalidate() {
        guard let compressionSession else { return }

        VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
        encodedWidth = 0
        encodedHeight = 0
    }

    private func compressionSession(for pixelBuffer: CVPixelBuffer) -> VTCompressionSession? {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))

        if compressionSession == nil || width != encodedWidth || height != encodedHeight {
            setupEncoder(width: width, height: height)
        }

        return compressionSession
    }

    private func setupEncoder(width: Int32, height: Int32) {
        invalidate()

        let res = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionCallback,
            refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            compressionSessionOut: &compressionSession
        )

        guard res == noErr, let compressionSession else {
            return
        }

        VTSessionSetProperty(compressionSession,
                             key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)
        VTSessionSetProperty(compressionSession,
                             key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(compressionSession,
                             key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: maxKeyInterval as CFTypeRef)
        VTSessionSetProperty(compressionSession,
                             key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: expectedFrameRate as CFTypeRef)
        VTSessionSetProperty(compressionSession,
                             key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Baseline_AutoLevel)

        let averageBitRate = targetBitRate(width: width, height: height)
        VTSessionSetProperty(compressionSession,
                             key: kVTCompressionPropertyKey_AverageBitRate,
                             value: averageBitRate as CFTypeRef)
        let dataRateLimits: [Int] = [averageBitRate * 2, 1]
        VTSessionSetProperty(compressionSession,
                             key: kVTCompressionPropertyKey_DataRateLimits,
                             value: dataRateLimits as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(compressionSession)

        encodedWidth = width
        encodedHeight = height
        sentConfig = false
        frameIndex = 0
    }

    private func targetBitRate(width: Int32, height: Int32) -> Int {
        let pixels = Int(width) * Int(height)
        switch pixels {
        case 0..<(640 * 480):
            return 1_000_000
        case 0..<(1280 * 720):
            return 2_000_000
        case 0..<(1920 * 1080):
            return 4_000_000
        default:
            return 6_000_000
        }
    }

    private let compressionCallback: VTCompressionOutputCallback = { refCon, _, status, _, sampleBuffer in
        guard status == noErr,
              let sampleBuffer,
              let refCon,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let encoder = Unmanaged<H264Encoder>.fromOpaque(refCon).takeUnretainedValue()

        var shouldSentConfig = !encoder.sentConfig
        if !shouldSentConfig {
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true).flatMap { $0 as NSArray }
            let dict = attachments?.firstObject as? NSDictionary
            let notSync = dict?[kCMSampleAttachmentKey_NotSync] as? Bool
            let isKeyframe = notSync != true
            shouldSentConfig = isKeyframe
        }
        
        guard let packet = encoder.makeAccessUnitPacket(from: sampleBuffer, includeParameterSets: shouldSentConfig),
              let outputHandler = encoder.outputHandler else {
            return
        }

        outputHandler(packet)

        if shouldSentConfig {
            encoder.sentConfig = true
        }
    }

    private func makeAccessUnitPacket(from sampleBuffer: CMSampleBuffer, includeParameterSets: Bool) -> Data? {
        var packet = Data()

        if includeParameterSets, !appendParameterSets(from: sampleBuffer, to: &packet) {
            return nil
        }

        guard appendNALUnits(from: sampleBuffer, to: &packet), !packet.isEmpty else {
            return nil
        }

        return packet
    }

    private func appendParameterSets(from sampleBuffer: CMSampleBuffer, to packet: inout Data) -> Bool {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return false }

        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var spsCount = 0
        
        var res = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDesc,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: &spsPointer,
                    parameterSetSizeOut: &spsSize,
                    parameterSetCountOut: &spsCount,
                    nalUnitHeaderLengthOut: nil
        )
        guard let spsPointer, res == noErr else {
            return false
        }
        appendAnnexBPacket(bytes: spsPointer, count: spsSize, to: &packet)

        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        var ppsCount = 0

        res = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer,
                parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: &ppsCount,
                nalUnitHeaderLengthOut: nil
        )
        guard let ppsPointer, res == noErr else {
            return false
        }
        appendAnnexBPacket(bytes: ppsPointer, count: ppsSize, to: &packet)
        return true
    }

    private func appendNALUnits(from sampleBuffer: CMSampleBuffer, to packet: inout Data) -> Bool {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return false }

        var length = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let res = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard let dataPointer, res == noErr else {
            return false
        }

        var offset = 0
        while offset < totalLength {
            var nalLength32: UInt32 = 0
            memcpy(&nalLength32, dataPointer.advanced(by: offset), 4)
            let nalLength = Int(CFSwapInt32BigToHost(nalLength32))
            let nalStart = offset + 4
            let nalPointer = UnsafeRawPointer(dataPointer.advanced(by: nalStart)).assumingMemoryBound(to: UInt8.self)
            appendAnnexBPacket(bytes: nalPointer, count: nalLength, to: &packet)
            offset += 4 + nalLength
        }

        return true
    }

    private func appendAnnexBPacket(bytes: UnsafePointer<UInt8>, count: Int, to packet: inout Data) {
        packet.reserveCapacity(packet.count + Self.annexBStartCode.count + count)
        packet.append(contentsOf: Self.annexBStartCode)
        packet.append(bytes, count: count)
    }
}
