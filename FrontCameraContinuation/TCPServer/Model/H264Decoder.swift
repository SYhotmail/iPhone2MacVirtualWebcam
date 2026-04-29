//
//  H264Decoder.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//


import VideoToolbox
import QuartzCore
import Combine
import Synchronization

protocol Decoding {
    func decode( _data: Data)
    func reset()
}

final class H264Decoder {

    private var formatDescription: CMFormatDescription?
    private var session: VTDecompressionSession?

    private var sps: Data?
    private var pps: Data?
    let decodedFramePublisher = PassthroughSubject<CMSampleBuffer, Never>()
    
    let lock = Mutex(())
    
    func reset() {
        lock.withLock { _ in
            resetForStreamCore()
        }
    }
    
    func decode(_ data: Data) {
        lock.withLock { _ in
            decodeCore(data)
        }
    }
    
    private func decodeCore(_ data: Data) {
        guard data.count > 4 else { return }
        // Detect NAL type
        let nalType = data[4] & 0x1F
        debugPrint("📦 NAL type:", nalType)
        
        switch nalType {
        case 7: // SPS
            let newSPS = data.advanced(by: 4)
            if sps != newSPS {
                resetDecoder()
                pps = nil
            }
            sps = newSPS
            debugPrint("📡 SPS received:", newSPS.count)
            createSessionFormatDescriptionOnNeed()

        case 8: // PPS
            let newPPS = data.advanced(by: 4)
            if pps != newPPS {
                resetDecoder()
            }
            pps = newPPS
            debugPrint("📡 PPS received:", newPPS.count)
            createSessionFormatDescriptionOnNeed()

        default:
            guard let session, let formatDescription else {
                debugPrint("⏳ Waiting for decoder setup...")
                return
            }

            Self.decodeFrame(data, session: session, formatDescription: formatDescription)
        }
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
                    debugPrint("❌ Failed to create format description:", status)
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
        debugPrint(sessionOut != nil ? "🎬 Created Decoder session" : "❌ Failed Decoder session")
        return Self.valueOnStatusSuccess(sessionOut, status: status)
    }

    private static func decodeFrame(_ data: Data, session: VTDecompressionSession, formatDescription: CMFormatDescription) {
        // Convert Annex-B → AVCC (replace start code with length)
        var length = UInt32(data.count - 4).bigEndian
        var buffer = Data(bytes: &length, count: 4)
        buffer.append(data.advanced(by: 4))

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
        
        guard Self.valueOnStatusSuccess(flags, status: decodeStatus) != nil else { return }
    }

    private static let decompressionCallback: VTDecompressionOutputCallback = {
        (refCon, _, status, _, imageBuffer, _, _) in

        guard let imageBuffer = valueOnStatusSuccess(imageBuffer, status: status), let refCon else { return }

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
        
        return Self.valueOnStatusSuccess(sampleBuffer, status:bufferStatus)
    }
    
    private static func valueOnStatusSuccess<T>(_ value: T?, status: OSStatus) -> T! {
        guard status == noErr else { return nil }
        assert(value != nil)
        return value
    }
    
    private static func valueOnStatusSuccess<T>(_ value: T?, status: OSStatus?) -> T! {
        status.flatMap { valueOnStatusSuccess(value, status: $0) }
    }

    private func handleDecodedFrame(_ pixelBuffer: CVImageBuffer) {
        
        guard let sampleBuffer = Self.makeSampleBuffer(from: pixelBuffer) else { return }

        decodedFramePublisher.send(sampleBuffer)
        
    }
}
