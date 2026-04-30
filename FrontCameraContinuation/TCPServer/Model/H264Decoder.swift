//
//  H264Decoder.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//


import VideoToolbox
import QuartzCore
import Combine

protocol Decoding {
    func decode( _data: Data)
    func reset()
}

final class H264Decoder {
    private static let maxQueuedDecodeOperations = 2 * 10

    private var formatDescription: CMFormatDescription?
    private var session: VTDecompressionSession?

    private var sps: Data?
    private var pps: Data?
    let decodedFramePublisher = PassthroughSubject<CMSampleBuffer, Never>()
    let queue: OperationQueue
    
    
    init() {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        // H.264 access units must stay in order for the decompression session.
        queue.maxConcurrentOperationCount = 1
        queue.name = "by.sy.H264Decoder.decodeQueue"
        self.queue = queue
    }
    
    func reset() {
        queue.addOperation { [weak self] in
            guard let self, !self.queue.isSuspended else {
                return
            }
            self.resetForStreamCore()
        }
    }
    
    func decode(_ data: Data) {
        guard data.count > 4 else { return }
        StreamDiagnostics.shared.mark(.decodeRequested)
        let nalUnits = Self.splitAnnexBNALUnits(in: data)
        guard !nalUnits.isEmpty else { return }

        if shouldDropNALUnits(nalUnits) {
            StreamDiagnostics.shared.mark(.decodeDropped)
            return
        }

        queue.addOperation { [weak self] in
            guard let self, !self.queue.isSuspended else {
                return
            }
            StreamDiagnostics.shared.mark(.decodeSubmitted)
            self.decodeAccessUnit(nalUnits)
        }
    }

    private func shouldDropNALUnits(_ nalUnits: [Data]) -> Bool {
        guard !nalUnits.contains(where: Self.isPriorityNALUnit) else {
            return false
        }

        return queue.operationCount >= Self.maxQueuedDecodeOperations
    }
    
    private func decodeAccessUnit(_ nalUnits: [Data]) {
        var frameNALUnits = [Data]()
        frameNALUnits.reserveCapacity(nalUnits.count)

        for nalUnit in nalUnits {
            guard nalUnit.count > 4 else { continue }
            let nalType = nalUnit[4] & 0x1F

            switch nalType {
            case 7: // SPS
                let newSPS = nalUnit.advanced(by: 4)
                if sps != newSPS {
                    resetDecoder()
                    pps = nil
                }
                sps = newSPS
                createSessionFormatDescriptionOnNeed()

            case 8: // PPS
                let newPPS = nalUnit.advanced(by: 4)
                if pps != newPPS {
                    resetDecoder()
                }
                pps = newPPS
                createSessionFormatDescriptionOnNeed()

            case 9: // AUD
                continue

            default:
                frameNALUnits.append(nalUnit)
            }
        }

        guard !frameNALUnits.isEmpty, let session, let formatDescription else {
            return
        }

        Self.decodeFrame(frameNALUnits, session: session, formatDescription: formatDescription)
    }

    private func resetDecoder() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        setSessionAndFormatDescription(with: nil)
    }
    
    private func setSessionAndFormatDescription(with description: CMFormatDescription?) {
        self.formatDescription = description
        session = description.flatMap { createDecompressionSession(formatDescription: $0) }
    }
    
    private func resetForStreamCore() {
        resetDecoder()
        sps = nil
        pps = nil
    }

    private func createSessionFormatDescriptionOnNeed() {
        guard session == nil else { return }
        guard let sps, let pps else { return }

        let formatDescription: CMFormatDescription? = sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                
                let ptrs = [spsPtr, ppsPtr]
                let parameterSetPointers = ptrs.map { $0.bindMemory(to: UInt8.self).baseAddress }.compactMap { $0 }
                
                guard parameterSetPointers.count == ptrs.count else {
                    return nil
                }

                let parameterSetSizes = ptrs.map(\.count)
                assert(parameterSetSizes.count == 2)
                
                var formatDescription: CMFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )
                
                guard let formatDescription = Self.valueOnStatusSuccess(formatDescription, status: status) else {
                    return nil
                }
                
                return formatDescription
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

    private static func decodeFrame(_ nalUnits: [Data], session: VTDecompressionSession, formatDescription: CMFormatDescription) {
        guard !nalUnits.isEmpty else { return }

        // Convert Annex-B access unit → AVCC by length-prefixing each NAL in the frame.
        assert(!Thread.isMainThread)
        var buffer = Data()
        for nalUnit in nalUnits {
            guard nalUnit.count > 4 else { continue }
            var length = UInt32(nalUnit.count - 4).bigEndian
            buffer.append(Data(bytes: &length, count: 4))
            buffer.append(nalUnit.advanced(by: 4))
        }

        guard !buffer.isEmpty else { return }

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
        
        guard let blockBuffer = Self.valueOnStatusSuccess(blockBuffer, status: status) else { return }

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
        
        guard Self.valueOnStatusSuccess((), status: replaceStatus) != nil else { return }

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

        guard let sampleBuffer = Self.valueOnStatusSuccess(sampleBuffer, status: createStatus) else { return }

        var flags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &flags
        )
        
        guard Self.valueOnStatusSuccess(flags, status: decodeStatus) != nil else {
            StreamDiagnostics.shared.mark(.decodeError)
            return
        }
    }

    private static let decompressionCallback: VTDecompressionOutputCallback = {
        (refCon, _, status, _, imageBuffer, _, _) in
        guard let refCon else { return }
        guard let imageBuffer = valueOnStatusSuccess(imageBuffer, status: status) else {
            StreamDiagnostics.shared.mark(.decodeError)
            return
        }

        let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()

        decoder.handleDecodedFrame(imageBuffer)
    }
    
    private static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        )
        
        guard let format = Self.valueOnStatusSuccess(format, status: status) else { return nil }

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

        guard let sampleBuffer = Self.valueOnStatusSuccess(sampleBuffer, status: bufferStatus) else {
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
    
    private static func valueOnStatusSuccess<T>(_ value: T?, status: OSStatus) -> T! {
        guard status == noErr else { return nil }
        assert(value != nil)
        return value
    }
    
    private static func valueOnStatusSuccess<T>(_ value: T?, status: OSStatus?) -> T! {
        status.flatMap { valueOnStatusSuccess(value, status: $0) }
    }

    private static func splitAnnexBNALUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else {
            return []
        }

        var startOffsets = [Int]()
        var index = 0
        while index <= bytes.count - 4 {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                startOffsets.append(index)
                index += 4
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
            guard endOffset - startOffset > 4 else {
                continue
            }

            nalUnits.append(data.subdata(in: startOffset..<endOffset))
        }

        return nalUnits
    }

    private static func isPriorityNALUnit(_ data: Data) -> Bool {
        guard data.count > 4 else {
            return false
        }

        let nalType = data[4] & 0x1F
        return nalType == 7 || nalType == 8 || nalType == 5
    }

    private func handleDecodedFrame(_ pixelBuffer: CVImageBuffer) {
        guard let sampleBuffer = Self.makeSampleBuffer(from: pixelBuffer) else { return }
        StreamDiagnostics.shared.mark(.decodeOutput)
        decodedFramePublisher.send(sampleBuffer)
    }
}
