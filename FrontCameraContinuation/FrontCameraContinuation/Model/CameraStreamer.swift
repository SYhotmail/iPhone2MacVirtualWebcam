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

        VTCompressionSessionPrepareToEncodeFrames(compressionSession!)
    }

    private let compressionCallback: VTCompressionOutputCallback = {
        (refCon, _, status, _, sampleBuffer) in

        guard status == noErr,
              let sampleBuffer = sampleBuffer,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let streamer = Unmanaged<CameraStreamer>.fromOpaque(refCon!).takeUnretainedValue()

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        let data = Data(bytes: dataPointer!, count: totalLength)
        streamer.send(data)
    }

    // MARK: - Capture delegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let session = compressionSession else { return }

        let pts = CMTime(value: CMTimeValue(CACurrentMediaTime() * 1000), timescale: 1000)

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }
}
