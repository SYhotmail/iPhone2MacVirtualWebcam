import AVFoundation
import VideoToolbox
import QuartzCore

actor H264Encoder {
    typealias OutputHandler = @Sendable (Data) -> Void
    
    /// `CVImageBuffer` is a CF type and not modeled as `Sendable`, but we hand off
    /// retained buffer references from the capture callback to the encoder actor.
    /// The actor remains the only encoder-side consumer after scheduling.
    private struct SendableImageBuffer: @unchecked Sendable {
        let value: CVImageBuffer
    }

    private static let annexBStartCode = [UInt8](arrayLiteral: 0, 0, 0, 1)
    private let expectedFrameRate: Int
    private let maxKeyInterval: Int
    
    private var compressionSession: VTCompressionSession?
    private var sentConfig = false
    private var frameIndex = 0
    private var encodedSize: CGSize = .zero
    
    private let outputHandler: OutputHandler

    init(expectedFrameRate: Int = VirtualCameraConfiguration.frameRate,
         maxKeyInterval: Int = VirtualCameraConfiguration.frameRate,
         outputHandler: @escaping OutputHandler) {
        assert(expectedFrameRate > 0 && maxKeyInterval > 0)
        self.expectedFrameRate = expectedFrameRate
        self.maxKeyInterval = maxKeyInterval
        self.outputHandler = outputHandler
    }
    
    nonisolated
    func scheduleToEncode(imageBuffer: CVImageBuffer) {
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        let size = CGSize(width: width,
                          height: height)
        let sendableImageBuffer = SendableImageBuffer(value: imageBuffer) // wrapper around CVImageBuffer..
        
        Task { @concurrent [sendableImageBuffer] in
            await self.encode(sendableImageBuffer, newSize: size)
        }
    }

    @discardableResult
    private func encode(_ imageBuffer: sending SendableImageBuffer, newSize: CGSize) -> Bool {
        guard let session = compressionSession(newSize: newSize) else { return false }

        assert(!Thread.isMainThread)
        
        let pts = CMTime(value: CMTimeValue(CACurrentMediaTime() * 1000), timescale: 1000)
        frameIndex += 1
        let shouldForceKeyframe = frameIndex % maxKeyInterval == 0
        let frameProperties = shouldForceKeyframe
        ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] : nil

        let firstParam = !sentConfig
        
        let res = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer.value,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties.flatMap { $0 as CFDictionary },
            infoFlagsOut: nil) { status, flags, sampleBuffer in
                guard status == noErr,
                      let sampleBuffer,
                      CMSampleBufferDataIsReady(sampleBuffer), let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
                
                let shouldSendConfig = firstParam || Self.shouldSendConfig(for: sampleBuffer)
                
                let formatDesc = shouldSendConfig ? CMSampleBufferGetFormatDescription(sampleBuffer) : nil
                
                guard let packetData = Self.makeAccessUnitPacket(formatDesc: formatDesc,
                                                                 blockBuffer: blockBuffer,
                                                                 includeParameterSets: shouldSendConfig) else {
                    return
                }
                
                Task { @concurrent [weak self] in
                    guard let self else {
                        return
                    }
                    assert(!Thread.isMainThread)
                    
                    outputHandler(packetData)
                    
                    if firstParam {
                        await setSentConfig(true)
                    }
                }
            }
        
        return res == noErr
    }
    
    private func setSentConfig( _ sentConfig: Bool) {
        self.sentConfig = sentConfig
    }

    private func invalidate() {
        guard let compressionSession else { return }

        VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(compressionSession)
        
        resetSession()
    }
    
    private func resetSession() {
        compressionSession = nil
        encodedSize = .zero
        sentConfig = false
        frameIndex = 0
    }
    
    nonisolated
    func scheduleToInvalidate() {
        Task { @concurrent [weak self] in
            await self?.invalidate()
        }
    }

    private func compressionSession(newSize: CGSize) -> VTCompressionSession? {
        if compressionSession == nil || newSize != encodedSize {
            invalidate()
            compressionSession = setupEncoder(size: newSize)
            
            if compressionSession != nil {
                encodedSize = newSize
            }
        }

        return compressionSession
    }

    private func setupEncoder(size: CGSize) -> VTCompressionSession? {
        var compressionSession: VTCompressionSession?
        
        let res = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(size.width),
            height: Int32(size.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            compressionSessionOut: &compressionSession
        )

        guard res == noErr, let compressionSession else {
            return compressionSession
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

        let averageBitRate = Self.targetBitRate(size: size)
        VTSessionSetProperty(compressionSession,
                             key: kVTCompressionPropertyKey_AverageBitRate,
                             value: averageBitRate as CFTypeRef)
        let dataRateLimits: [Int] = [averageBitRate * 2, 1]
        VTSessionSetProperty(compressionSession,
                             key: kVTCompressionPropertyKey_DataRateLimits,
                             value: dataRateLimits as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(compressionSession)
        
        return compressionSession
    }

    private static func targetBitRate(size: CGSize) -> Int {
        let pixels = Int(size.width * size.height)
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

    private static func shouldSendConfig(for sampleBuffer: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true).flatMap { $0 as NSArray }
        let dict = attachments?.firstObject as? NSDictionary
        let notSync = dict?[kCMSampleAttachmentKey_NotSync] as? Bool
        return notSync != true
    }

    private static func makeAccessUnitPacket(formatDesc: CMFormatDescription?,
                                             blockBuffer: CMBlockBuffer,
                                             includeParameterSets: Bool) -> Data? {
        var packet = Data()
        
        guard !includeParameterSets || formatDesc.flatMap({ appendParameterSets(formatDesc: $0, to: &packet) }) == true else {
            return nil
        }

        guard appendNALUnits(blockBuffer: blockBuffer, to: &packet) else {
            return nil
        }

        return !packet.isEmpty ? packet : nil
    }

    private static func appendParameterSets(formatDesc: CMFormatDescription,
                                            to packet: inout Data) -> Bool {
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

    private static func appendNALUnits(blockBuffer: CMBlockBuffer?, to packet: inout Data) -> Bool {
        guard let blockBuffer else { return false }

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

    private static func appendAnnexBPacket(bytes: UnsafePointer<UInt8>, count: Int, to packet: inout Data) {
        packet.reserveCapacity(packet.count + annexBStartCode.count + count)
        packet.append(contentsOf: annexBStartCode)
        packet.append(bytes, count: count)
    }
}
