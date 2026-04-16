//
//  CameraStreamer.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//


import AVFoundation
import VideoToolbox
import Network

struct StreamManager {
    private let cameraStreamer = CameraStreamer()
    
    func startStreaming(host: String = "192.168.1.10",
                        port: UInt16 = 9999) {
        cameraStreamer.startStreaming(
            host: host,
            port: port,
            position: .front
        )
    }
    
    func stopStreaming() {
        cameraStreamer.stopStreaming()
    }
}

final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private var compressionSession: VTCompressionSession?
    private var connection: NWConnection?
    private var sentConfig = false
    private var frameIndex: Int = 0

    func startStreaming(host: String, port: UInt16, position: AVCaptureDevice.Position) {
        let res = setupConnection(host: host, port: port)
        assert(res)
        setupEncoder(width: 1280, height: 720)
        try? setupCamera(position: position)
    }
    
    func stopStreaming() {
        DispatchQueue.global(qos: .default).async { [weak session] in
            session?.stopRunning()
        }
        connection?.cancel()
    }

    // MARK: - TCP

    @discardableResult
    private func setupConnection(host: String, port: UInt16) -> Bool {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            return false
        }
        
        let endpoint = NWEndpoint.Host(host)
        let connection = NWConnection(host: endpoint, port: p, using: .tcp)
        
        connection.stateUpdateHandler = { newState in
            debugPrint("New State \(newState)")
        }
        connection.pathUpdateHandler = { newPath in
            debugPrint("New Path \(newPath.debugDescription)")
        }
        
        connection.viabilityUpdateHandler = { isViable in
            debugPrint("isViable \(isViable)")
        }
        
        connection.betterPathUpdateHandler = { newHasBetterPath in
            debugPrint("newHasBetterPath \(newHasBetterPath)")
        }
        
        connection.start(queue: .global())
        self.connection = connection
        return true
    }

    private func send(_ data: Data) {
        var size = UInt32(data.count).bigEndian
        let header = Data(bytes: &size, count: 4)
        
        connection?.send(content: header + data, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed({ error in
            guard let error else { return }
            debugPrint("!!! Error: \(error.localizedDescription)")
        }))
    }

    // MARK: - Camera

    private func setupCamera(position: AVCaptureDevice.Position) throws {
        guard session.inputs.isEmpty else {
            return
        }
        session.beginConfiguration()

        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)!
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
        }
        
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera"))

        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()
        DispatchQueue.global(qos: .default).async { [weak session] in
            session?.startRunning()
        }
    }

    // MARK: - Encoder

    private func setupEncoder(width: Int32, height: Int32) {
        VTCompressionSessionCreate(
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

        VTSessionSetProperty(compressionSession!,
                             key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue)

        VTSessionSetProperty(compressionSession!,
                             key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)

        VTSessionSetProperty(compressionSession!,
                             key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: 30 as CFTypeRef)

        VTSessionSetProperty(compressionSession!,
                             key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Baseline_AutoLevel)

        VTCompressionSessionPrepareToEncodeFrames(compressionSession!)
    }

    private let compressionCallback: VTCompressionOutputCallback = {
        (refCon, _, status, _, sampleBuffer) in

        guard status == noErr,
              let sampleBuffer = sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let streamer = Unmanaged<CameraStreamer>.fromOpaque(refCon!).takeUnretainedValue()

        // Detect keyframe
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)! as NSArray
        let dict = attachments[0] as! NSDictionary
        let isKeyframe = !(dict[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        
        if isKeyframe || !streamer.sentConfig {
            print("📡 isKeyframe:", isKeyframe)
            
            streamer.sendParameterSets(from: sampleBuffer)
            streamer.sentConfig = true
        }

        // Extract and send NAL units in Annex-B format
        let nalUnits = streamer.extractNALUnits(from: sampleBuffer)
        for nal in nalUnits {
            var packet = Data([0,0,0,1]) // start code
            packet.append(nal)
            streamer.send(packet)
        }
    }

    // MARK: - H264 helpers

    private func sendParameterSets(from sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        var spsPointer: UnsafePointer<UInt8>?
        var spsSize: Int = 0
        var spsCount: Int = 0

        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize: Int = 0
        var ppsCount: Int = 0

        // Extract SPS
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount,
            nalUnitHeaderLengthOut: nil
        )

        // Extract PPS
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDesc,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: &ppsCount,
            nalUnitHeaderLengthOut: nil
        )

        guard let spsPointer, let ppsPointer else {
            print("❌ Failed to extract SPS/PPS")
            return
        }

        let sps = Data(bytes: spsPointer, count: spsSize)
        let pps = Data(bytes: ppsPointer, count: ppsSize)

        print("📡 Sending SPS:", sps.count)
        print("📡 Sending PPS:", pps.count)

        let startCode = Data([0, 0, 0, 1])

        // ✅ Send SPS separately
        var spsPacket = Data()
        spsPacket.append(startCode)
        spsPacket.append(sps)
        send(spsPacket)

        // ✅ Send PPS separately
        var ppsPacket = Data()
        ppsPacket.append(startCode)
        ppsPacket.append(pps)
        send(ppsPacket)
    }

    private func extractNALUnits(from sampleBuffer: CMSampleBuffer) -> [Data] {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return [] }

        var length = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        var offset = 0
        var nalUnits: [Data] = []

        while offset < totalLength {
            var nalLength32: UInt32 = 0
            memcpy(&nalLength32, dataPointer!.advanced(by: offset), 4)
            let nalLength = Int(CFSwapInt32BigToHost(nalLength32))

            let nalStart = offset + 4
            let nalData = Data(bytes: dataPointer!.advanced(by: nalStart), count: nalLength)

            nalUnits.append(nalData)

            offset += 4 + nalLength
        }

        return nalUnits
    }

    // MARK: - Capture delegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let session = compressionSession else { return }

        let pts = CMTime(value: CMTimeValue(CACurrentMediaTime() * 1000), timescale: 1000)

        frameIndex += 1
        let shouldForceKeyframe = frameIndex % 30 == 0

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
}
