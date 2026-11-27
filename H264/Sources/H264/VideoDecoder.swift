import CoreMedia
import QuartzCore
import Synchronization
@preconcurrency import Combine
import VideoToolbox

public actor VideoDecoder {
    public struct SendableSampleBuffer: @unchecked Sendable {
        public let value: CMSampleBuffer

        public init(value: CMSampleBuffer) {
            self.value = value
        }
    }

    private static let annexBStartCodeLength = VideoEncoder.annexBStartCode.count
    private static let avccNALUnitLengthFieldSize = 4

    private var formatDescription: CMFormatDescription?
    private var session: VTDecompressionSession?

    private var vps: Data?
    private var sps: Data?
    private var pps: Data?

    private enum NALUnitType {
        static let vps: UInt8 = 32
        static let sps: UInt8 = 33
        static let pps: UInt8 = 34
        static let accessUnitDelimiter: UInt8 = 35
    }

    nonisolated private let decodedFramePublisher = PassthroughSubject<SendableSampleBuffer, Never>()
    nonisolated let streamDiagnostics: StreamDiagnostics

    nonisolated public var publisher: AnyPublisher<SendableSampleBuffer, Never> {
        decodedFramePublisher.eraseToAnyPublisher()
    }

    private enum Command: Sendable {
        case decode(Data)
        case reset
    }

    /// Serial FIFO of work. Spawning a separate `Task` per frame does not guarantee
    /// the actor runs them in arrival order, and HEVC frames decoded out of order
    /// show up as dropped/jumping frames during motion.
    nonisolated private let commands: AsyncStream<Command>.Continuation

    public init() {
        self.streamDiagnostics = .shared
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self, bufferingPolicy: .unbounded)
        self.commands = continuation
        Task { [weak self] in
            for await command in stream {
                guard let self else { return }
                await self.handle(command)
            }
        }
    }

    deinit {
        commands.finish()
    }

    private func handle(_ command: Command) {
        switch command {
        case .decode(let data):
            decode(data)
        case .reset:
            reset()
        }
    }

    nonisolated public func scheduleToDecode(_ data: Data) {
        commands.yield(.decode(data))
    }

    nonisolated public func scheduleToReset() {
        commands.yield(.reset)
    }

    public func reset() {
        resetForStreamCore()
    }

    private func decode(_ data: Data) {
        streamDiagnostics.mark(.tcpReceived)
        guard data.count > Self.annexBStartCodeLength else {
            return
        }
        streamDiagnostics.mark(.decodeRequested)
        let accessUnitNALUnits = Self.splitAnnexBNALUnits(in: data)
        guard !accessUnitNALUnits.isEmpty else {
            return
        }
        streamDiagnostics.mark(.decodeSubmitted)
        decodeAccessUnit(accessUnitNALUnits)
    }

    private func decodeAccessUnit(_ nalUnits: [Data]) {
        var frameNALUnits = [Data]()
        frameNALUnits.reserveCapacity(nalUnits.count)

        for nalUnit in nalUnits {
            guard nalUnit.count > Self.annexBStartCodeLength else {
                continue
            }
            let nalType = (nalUnit[Self.annexBStartCodeLength] >> 1) & 0x3F
            let payload = nalUnit.advanced(by: Self.annexBStartCodeLength)

            // A changed parameter set (e.g. a new size after rotation) needs a new session.
            switch nalType {
            case NALUnitType.vps:
                if vps != payload {
                    resetDecoder()
                    vps = payload
                    sps = nil
                    pps = nil
                }
                createSessionFormatDescriptionOnNeed()
            case NALUnitType.sps:
                if sps != payload {
                    resetDecoder()
                    sps = payload
                    pps = nil
                }
                createSessionFormatDescriptionOnNeed()
            case NALUnitType.pps:
                if pps != payload {
                    resetDecoder()
                    pps = payload
                }
                createSessionFormatDescriptionOnNeed()
            case NALUnitType.accessUnitDelimiter:
                continue
            default:
                frameNALUnits.append(nalUnit)
            }
        }

        guard !frameNALUnits.isEmpty, let session, let formatDescription else {
            return
        }

        decodeFrame(frameNALUnits, session: session, formatDescription: formatDescription)
    }

    private func resetDecoder() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        setSessionAndFormatDescription(with: nil)
    }

    private func setSessionAndFormatDescription(with description: CMFormatDescription?) {
        formatDescription = description
        session = description.flatMap { createDecompressionSession(formatDescription: $0) }
    }

    private func resetForStreamCore() {
        resetDecoder()
        vps = nil
        sps = nil
        pps = nil
    }

    private func createSessionFormatDescriptionOnNeed() {
        guard session == nil else {
            return
        }
        guard let vps, let sps, let pps else {
            return
        }

        let formatDescription: CMFormatDescription? = vps.withUnsafeBytes { vpsPtr in
            sps.withUnsafeBytes { spsPtr in
                pps.withUnsafeBytes { ppsPtr -> CMFormatDescription? in
                    let ptrs = [vpsPtr, spsPtr, ppsPtr]
                    let parameterSetPointers = ptrs.compactMap { $0.bindMemory(to: UInt8.self).baseAddress }

                    guard parameterSetPointers.count == ptrs.count else {
                        return nil
                    }

                    var formatDescription: CMFormatDescription?
                    let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: ptrs.count,
                        parameterSetPointers: parameterSetPointers,
                        parameterSetSizes: ptrs.map(\.count),
                        nalUnitHeaderLength: Int32(Self.avccNALUnitLengthFieldSize),
                        extensions: nil,
                        formatDescriptionOut: &formatDescription
                    )

                    return Self.valueOnStatusSuccess(formatDescription, status: status)
                }
            }
        }

        setSessionAndFormatDescription(with: formatDescription)
    }

    private func createDecompressionSession(formatDescription: CMFormatDescription) -> VTDecompressionSession? {
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.decompressionCallback,
            decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        var sessionOut: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &callback,
            decompressionSessionOut: &sessionOut
        )
        return Self.valueOnStatusSuccess(sessionOut, status: status)
    }

    private func decodeFrame(_ nalUnits: [Data], session: VTDecompressionSession, formatDescription: CMFormatDescription) {
        guard !nalUnits.isEmpty else {
            return
        }

        assert(!Thread.isMainThread)
        var buffer = Data()
        for nalUnit in nalUnits {
            guard nalUnit.count > Self.annexBStartCodeLength else {
                continue
            }
            var length = UInt32(nalUnit.count - Self.annexBStartCodeLength).bigEndian
            buffer.append(Data(bytes: &length, count: Self.avccNALUnitLengthFieldSize))
            buffer.append(nalUnit.advanced(by: Self.annexBStartCodeLength))
        }

        guard !buffer.isEmpty else {
            return
        }

        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: buffer.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: buffer.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard let blockBuffer = Self.valueOnStatusSuccess(blockBuffer, status: status) else {
            return
        }

        let replaceStatus = buffer.withUnsafeBytes { ptr in
            ptr.baseAddress.flatMap { baseAddress in
                CMBlockBufferReplaceDataBytes(
                    with: baseAddress,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: buffer.count
                )
            }
        }

        guard Self.valueOnStatusSuccess((), status: replaceStatus) != nil else {
            return
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )

        let createStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard let sampleBuffer = Self.valueOnStatusSuccess(sampleBuffer, status: createStatus) else {
            return
        }

        var flags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &flags
        )

        guard Self.valueOnStatusSuccess(flags, status: decodeStatus) != nil else {
            streamDiagnostics.mark(.decodeError)
            return
        }
    }

    private static let decompressionCallback: VTDecompressionOutputCallback = {
        (refCon, _, status, _, imageBuffer, _, _) in
        guard let refCon else {
            return
        }
        guard let imageBuffer = valueOnStatusSuccess(imageBuffer, status: status) else {
            StreamDiagnostics.shared.mark(.decodeError)
            return
        }

        let decoder = Unmanaged<VideoDecoder>.fromOpaque(refCon).takeUnretainedValue()
        guard let sampleBuffer = makeSampleBuffer(from: imageBuffer) else {
            return
        }
        // Publish synchronously from the VideoToolbox callback so frames keep their
        // decode order (a Task per frame can reorder them).
        decoder.streamDiagnostics.mark(.decodeOutput)
        decoder.decodedFramePublisher.send(SendableSampleBuffer(value: sampleBuffer))
    }

    nonisolated
    public static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        )

        guard let format = valueOnStatusSuccess(format, status: status) else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let bufferStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard let sampleBuffer = valueOnStatusSuccess(sampleBuffer, status: bufferStatus) else {
            return nil
        }

        markDisplayImmediately(sampleBuffer)
        return sampleBuffer
    }

    private static func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) else {
            return
        }

        let mutableAttachments = unsafeDowncast(attachments, to: CFMutableArray.self)
        guard CFArrayGetCount(mutableAttachments) > 0 else {
            return
        }

        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(mutableAttachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            attachment,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    static func valueOnStatusSuccess<T>(_ value: T?, status: OSStatus) -> T! {
        guard status == noErr else {
            return nil
        }
        assert(value != nil)
        return value
    }

    static func valueOnStatusSuccess<T>(_ value: T?, status: OSStatus?) -> T! {
        status.flatMap { valueOnStatusSuccess(value, status: $0) }
    }

    @_spi(Testing) public static func splitAnnexBNALUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count > annexBStartCodeLength else {
            return []
        }

        var startOffsets = [Int]()
        var index = 0
        while index <= bytes.count - annexBStartCodeLength {
            if bytes[index..<index + annexBStartCodeLength] == VideoEncoder.annexBStartCode[0..<annexBStartCodeLength] {
                startOffsets.append(index)
                index += annexBStartCodeLength
            } else {
                index += 1
            }
        }

        guard !startOffsets.isEmpty else {
            return []
        }

        var nalUnits = [Data]()
        nalUnits.reserveCapacity(startOffsets.count)

        for (offsetIndex, startOffset) in startOffsets.enumerated() {
            let endOffset = offsetIndex + 1 < startOffsets.count ? startOffsets[offsetIndex + 1] : bytes.count
            guard endOffset - startOffset > annexBStartCodeLength else {
                continue
            }

            nalUnits.append(data.subdata(in: startOffset..<endOffset))
        }

        return nalUnits
    }
}

