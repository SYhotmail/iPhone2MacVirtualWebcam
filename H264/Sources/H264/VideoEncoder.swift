import AVFoundation
import QuartzCore
import VideoToolbox

public actor VideoEncoder {
    /// Receives each encoded access unit in decode order, and whether it is a keyframe
    /// (a sync frame carrying VPS/SPS/PPS, decodable on its own).
    public typealias OutputHandler = @Sendable (_ packet: Data, _ isKeyframe: Bool) -> Void

    /// `CVImageBuffer` is a CF type and not modeled as `Sendable`, but we hand off
    /// retained buffer references from the capture callback to the encoder actor.
    /// The actor remains the only encoder-side consumer after scheduling.
    private struct SendableImageBuffer: @unchecked Sendable {
        let value: CVImageBuffer
    }

    static let annexBStartCode = [UInt8](arrayLiteral: 0, 0, 0, 1)
    private let expectedFrameRate: Int
    private let maxKeyInterval: Int

    private var compressionSession: VTCompressionSession?
    private var sentConfig = false
    private var frameIndex = 0
    private var forceNextKeyframe = false
    private var encodedSize: CGSize = .zero

    private let outputHandler: OutputHandler

    private enum Command: Sendable {
        case encode(SendableImageBuffer, size: CGSize)
        case forceKeyframe
        case invalidate
    }

    /// Serial FIFO of work. A `Task` per frame does not run in arrival order, which
    /// interleaves old- and new-size frames on rotation and reorders packets.
    nonisolated private let commands: AsyncStream<Command>.Continuation

    public init(
        expectedFrameRate: Int = 30,
        maxKeyInterval: Int = 30,
        outputHandler: @escaping OutputHandler
    ) {
        assert(expectedFrameRate > 0 && maxKeyInterval > 0)
        self.expectedFrameRate = expectedFrameRate
        self.maxKeyInterval = maxKeyInterval
        self.outputHandler = outputHandler
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self, bufferingPolicy: .unbounded)
        self.commands = continuation
        Task { @concurrent [weak self] in
            for await command in stream {
                guard let self, !Task.isCancelled else { return }
                await self.handle(command)
            }
        }
    }

    deinit {
        commands.finish()
    }

    private func handle(_ command: Command) {
        switch command {
        case let .encode(imageBuffer, size):
            encode(imageBuffer, newSize: size)
        case .forceKeyframe:
            forceNextKeyframe = true
        case .invalidate:
            invalidate()
        }
    }

    nonisolated public func scheduleToEncode(imageBuffer: CVImageBuffer) {
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        commands.yield(.encode(SendableImageBuffer(value: imageBuffer), size: CGSize(width: width, height: height)))
    }

    /// Makes the next encoded frame a keyframe, e.g. after the receiver lost frames.
    nonisolated public func scheduleToForceKeyframe() {
        commands.yield(.forceKeyframe)
    }

    @discardableResult
    private func encode(_ imageBuffer: SendableImageBuffer, newSize: CGSize) -> Bool {
        guard let session = compressionSession(newSize: newSize) else {
            return false
        }

        assert(!Thread.isMainThread)

        let pts = CMTime(value: CMTimeValue(CACurrentMediaTime() * 1000), timescale: 1000)
        frameIndex += 1
        let shouldForceKeyframe = forceNextKeyframe || frameIndex % maxKeyInterval == 0
        forceNextKeyframe = false
        let frameProperties = shouldForceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true]
            : nil

        let firstParam = !sentConfig
        let outputHandler = outputHandler

        let res = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer.value,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties.flatMap { $0 as CFDictionary },
            infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard let sampleBuffer = VideoDecoder.valueOnStatusSuccess(sampleBuffer, status: status),
                  CMSampleBufferDataIsReady(sampleBuffer),
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                return
            }

            let isKeyframe = Self.shouldSendConfig(for: sampleBuffer)
            let shouldSendConfig = firstParam || isKeyframe
            let formatDesc = shouldSendConfig ? CMSampleBufferGetFormatDescription(sampleBuffer) : nil

            guard let packetData = Self.makeAccessUnitPacket(
                formatDesc: formatDesc,
                blockBuffer: blockBuffer,
                includeParameterSets: shouldSendConfig
            ) else {
                return
            }

            // VideoToolbox calls this in decode order for a session; deliver
            // synchronously so packets keep that order.
            outputHandler(packetData, isKeyframe)
        }

        if res == noErr {
            sentConfig = true
        }
        return res == noErr
    }

    private func invalidate() {
        guard let compressionSession else {
            return
        }

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

    nonisolated public func scheduleToInvalidate() {
        commands.yield(.invalidate)
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
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            compressionSessionOut: &compressionSession
        )

        guard let compressionSession = VideoDecoder.valueOnStatusSuccess(compressionSession, status: res) else {
            return nil
        }

        VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse
        )
        VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: maxKeyInterval as CFTypeRef
        )
        VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: expectedFrameRate as CFTypeRef
        )
        VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_HEVC_Main_AutoLevel
        )

        let averageBitRate = Self.targetBitRate(size: size)
        VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: averageBitRate as CFTypeRef
        )
        let dataRateLimits: [Int] = [averageBitRate * 2, 1]
        VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: dataRateLimits as CFArray
        )

        VTCompressionSessionPrepareToEncodeFrames(compressionSession)

        return compressionSession
    }

    /// HEVC needs roughly 30% less bitrate than H.264 for the same quality.
    @_spi(Testing) public static func targetBitRate(size: CGSize) -> Int {
        let pixels = Int(size.width * size.height)
        switch pixels {
        case 0..<(640 * 480):
            return 700_000
        case 0..<(1280 * 720):
            return 1_400_000
        case 0..<(1920 * 1080):
            return 2_800_000
        default:
            return 4_200_000
        }
    }

    private static func shouldSendConfig(for sampleBuffer: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
            .flatMap { $0 as NSArray }
        let dict = attachments?.firstObject as? NSDictionary
        let notSync = dict?[kCMSampleAttachmentKey_NotSync] as? Bool
        return notSync != true
    }

    private static func makeAccessUnitPacket(
        formatDesc: CMFormatDescription?,
        blockBuffer: CMBlockBuffer,
        includeParameterSets: Bool
    ) -> Data? {
        var packet = Data()

        guard !includeParameterSets || formatDesc.flatMap({ appendParameterSets(formatDesc: $0, to: &packet) }) == true else {
            return nil
        }

        guard appendNALUnits(blockBuffer: blockBuffer, to: &packet) else {
            return nil
        }

        return !packet.isEmpty ? packet : nil
    }

    /// Appends every HEVC parameter set (VPS, SPS, PPS, in that order) as Annex-B units.
    private static func appendParameterSets(formatDesc: CMFormatDescription, to packet: inout Data) -> Bool {
        var parameterSetCount = 0
        var index = 0
        repeat {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let res = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: nil
            )
            guard let pointer = VideoDecoder.valueOnStatusSuccess(pointer, status: res) else {
                return false
            }
            appendAnnexBPacket(bytes: pointer, count: size, to: &packet)
            index += 1
        } while index < parameterSetCount
        return true
    }

    private static func appendNALUnits(blockBuffer: CMBlockBuffer?, to packet: inout Data) -> Bool {
        guard let blockBuffer else {
            return false
        }

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

        guard let dataPointer = VideoDecoder.valueOnStatusSuccess(dataPointer, status: res) else {
            return false
        }

        var offset = 0
        var startPointer = UnsafeMutableRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self)
        while offset < totalLength {
            var nalLength32: UInt32 = 0
            let nalCount = annexBStartCode.count
            assert(nalCount == 4)
            memcpy(&nalLength32, startPointer, nalCount)
            let nalLength = Int(CFSwapInt32BigToHost(nalLength32))
            startPointer += nalCount
            offset += nalCount
            
            appendAnnexBPacket(bytes: startPointer, count: nalLength, to: &packet)
            startPointer += nalLength
            offset += nalLength
        }

        return true
    }

    private static func appendAnnexBPacket(bytes: UnsafePointer<UInt8>, count: Int, to packet: inout Data) {
        packet.reserveCapacity(packet.count + annexBStartCode.count + count)
        packet.append(contentsOf: annexBStartCode)
        packet.append(bytes, count: count)
    }
}
