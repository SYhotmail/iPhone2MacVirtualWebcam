@preconcurrency import AVFoundation
import VideoToolbox
import QuartzCore

final class H264Encoder {
    typealias OutputHandler = (Data) -> Void

    private static let annexBStartCode = [UInt8](arrayLiteral: 0, 0, 0, 1)

    private var compressionSession: VTCompressionSession?
    private var sentConfig = false
    private var frameIndex = 0
    private var encodedWidth: Int32 = 0
    private var encodedHeight: Int32 = 0
    static let maxKeyInterval = 30
    var outputHandler: OutputHandler!


    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let session = compressionSession(for: pixelBuffer) else { return }

        assert(!Thread.isMainThread)
        
        let pts = CMTime(value: CMTimeValue(CACurrentMediaTime() * 1000), timescale: 1000)
        frameIndex += 1
        let shouldForceKeyframe = frameIndex % Self.maxKeyInterval == 0
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
                             value: Self.maxKeyInterval as CFTypeRef)
        VTSessionSetProperty(compressionSession,
                             key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Baseline_AutoLevel)

        VTCompressionSessionPrepareToEncodeFrames(compressionSession)

        encodedWidth = width
        encodedHeight = height
        sentConfig = false
        frameIndex = 0
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
        
        if shouldSentConfig {
            encoder.sendParameterSets(from: sampleBuffer)
            encoder.sentConfig = true
        }

        encoder.sendNALUnits(from: sampleBuffer)
    }

    private func sendParameterSets(from sampleBuffer: CMSampleBuffer) {
        guard let outputHandler, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

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
            return
        }
        outputHandler(annexBPacket(bytes: spsPointer, count: spsSize))

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
            return
        }
        outputHandler(annexBPacket(bytes: ppsPointer, count: ppsSize))
    }

    private func sendNALUnits(from sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

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

        guard let dataPointer, res == noErr, let outputHandler else {
            return
        }

        var offset = 0
        while offset < totalLength {
            var nalLength32: UInt32 = 0
            memcpy(&nalLength32, dataPointer.advanced(by: offset), 4)
            let nalLength = Int(CFSwapInt32BigToHost(nalLength32))
            let nalStart = offset + 4
            let nalPointer = UnsafeRawPointer(dataPointer.advanced(by: nalStart)).assumingMemoryBound(to: UInt8.self)
            outputHandler(annexBPacket(bytes: nalPointer, count: nalLength))
            offset += 4 + nalLength
        }
    }

    private func annexBPacket(bytes: UnsafePointer<UInt8>, count: Int) -> Data {
        var packet = Data()
        packet.reserveCapacity(Self.annexBStartCode.count + count)
        packet.append(contentsOf: Self.annexBStartCode)
        packet.append(bytes, count: count)
        return packet
    }
}
