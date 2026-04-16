//
//  H264Decoder.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//


import VideoToolbox
import QuartzCore
import AVFoundation

final class H264Decoder {

    private var formatDescription: CMFormatDescription?
    private var session: VTDecompressionSession?

    private var sps: Data?
    private var pps: Data?
    var displayLayer: AVSampleBufferDisplayLayer?
    
    func decode(_ data: Data) {
        // Detect NAL type
        
        guard data.count > 4 else { return }

        let nalType = data[4] & 0x1F
        print("📦 NAL type:", nalType)
        
        switch nalType {
        case 7: // SPS
            let newSPS = data.advanced(by: 4)
            if sps != newSPS {
                resetDecoder()
                pps = nil
            }
            sps = newSPS
            print("📡 SPS received:", sps!.count)
            createFormatDescriptionIfPossible()

        case 8: // PPS
            let newPPS = data.advanced(by: 4)
            if pps != newPPS {
                resetDecoder()
            }
            pps = newPPS
            print("📡 PPS received:", pps!.count)
            createFormatDescriptionIfPossible()

        default:
            guard let session else {
                print("⏳ Waiting for decoder setup...")
                return
            }

            decodeFrame(data)
        }
    }

    private func resetDecoder() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
    }

    func resetForStreamRestart() {
        resetDecoder()
        sps = nil
        pps = nil
    }

    private func createFormatDescriptionIfPossible() {
        guard let sps, let pps else { return }
        if session != nil { return }

        sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in

                let parameterSetPointers: [UnsafePointer<UInt8>] = [
                    spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                    ppsPtr.bindMemory(to: UInt8.self).baseAddress!
                ]

                let parameterSetSizes: [Int] = [sps.count, pps.count]

                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDescription
                )

                if status != noErr {
                    print("❌ Failed to create format description:", status)
                    return
                }
            }
        }

        if let formatDescription {
            createDecompressionSession(formatDescription: formatDescription)
        }
    }

    private func createDecompressionSession(formatDescription: CMFormatDescription) {
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionCallback,
            decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )

        VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )

        print("🎬 Decoder session created")
    }

    private func decodeFrame(_ data: Data) {
        guard let session, let formatDescription else { return }

        // Convert Annex-B → AVCC (replace start code with length)
        var length = UInt32(data.count - 4).bigEndian
        var buffer = Data(bytes: &length, count: 4)
        buffer.append(data.advanced(by: 4))

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
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

        buffer.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: blockBuffer!,
                offsetIntoDestination: 0,
                dataLength: buffer.count
            )
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )

        CMSampleBufferCreateReady(
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

        guard let sampleBuffer else { return }

        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
    }

    private let decompressionCallback: VTDecompressionOutputCallback = {
        (refCon, _, status, _, imageBuffer, _, _) in

        guard status == noErr, let imageBuffer else { return }

        let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon!).takeUnretainedValue()

        decoder.handleDecodedFrame(imageBuffer)
    }
    
    func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        )

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format!,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }

    private func handleDecodedFrame(_ pixelBuffer: CVImageBuffer) {
        guard let displayLayer else { return }
        guard let sampleBuffer = makeSampleBuffer(from: pixelBuffer) else { return }

        DispatchQueue.main.async {
            displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        }
    }
}
