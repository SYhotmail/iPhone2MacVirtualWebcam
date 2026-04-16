//
//  CameraStreamer.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//


import AVFoundation
import VideoToolbox
import Network
import UIKit

enum StreamSize: String, CaseIterable, Identifiable {
    case full
    case hd720
    case hd1920x1080
    case vga
    case medium
    case low

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full:
            return "Default(High Quality Output)"
        case .hd1920x1080:
            return "1920 x 1080"
        case .hd720:
            return "1280 x 720"
        case .vga:
            return "640 x 480"
        case .medium:
            return "Medium"
        case .low:
            return "Low"
        }
    }

    var sessionPreset: AVCaptureSession.Preset {
        switch self {
        case .full:
            return .high
        case .hd1920x1080:
            return .hd1920x1080
        case .hd720:
            return .hd1280x720
        case .vga:
            return .vga640x480
        case .medium:
            return .medium
        case .low:
            return .low
        }
    }
}

struct StreamManager {
    private let cameraStreamer = CameraStreamer()
    
    func startStreaming(host: String = "192.168.1.10",
                        port: UInt16 = 9999,
                        streamSize: StreamSize = .full) {
        cameraStreamer.startStreaming(
            host: host,
            port: port,
            position: .front,
            streamSize: streamSize
        )
    }
    
    func stopStreaming() {
        cameraStreamer.stopStreaming()
    }
    
    private func canSetPresent(size: StreamSize) -> Bool {
        cameraStreamer.session.canSetSessionPreset(size.sessionPreset)
    }
    
    func supportedCameraSessionPresets() -> [StreamSize] {
        StreamSize.allCases.filter {canSetPresent(size: $0)}
    }
}

final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()
    private var compressionSession: VTCompressionSession?
    private var connection: NWConnection?
    private var videoOutput: AVCaptureVideoDataOutput?
    private let captureQueue = DispatchQueue(label: "camera")
    private var sentConfig = false
    private var frameIndex: Int = 0
    private var encodedWidth: Int32 = 0
    private var encodedHeight: Int32 = 0
    private var shouldAutoResume = false
    private var currentHost: String?
    private var currentPort: UInt16?
    private var currentPosition: AVCaptureDevice.Position = .front
    private var currentStreamSize: StreamSize = .full

    func startStreaming(host: String, port: UInt16, position: AVCaptureDevice.Position, streamSize: StreamSize) {
        currentHost = host
        currentPort = port
        currentPosition = position
        currentStreamSize = streamSize
        shouldAutoResume = true

        let res = setupConnection(host: host, port: port)
        assert(res)
        try? setupCamera(position: position, streamSize: streamSize)
    }
    
    func stopStreaming() {
        shouldAutoResume = false
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        stopCaptureAndConnection()
    }

    // MARK: - TCP

    @discardableResult
    private func setupConnection(host: String, port: UInt16) -> Bool {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            return false
        }

        connection?.cancel()
        
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

    private func setupCamera(position: AVCaptureDevice.Position, streamSize: StreamSize) throws {
        guard session.inputs.isEmpty else {
            applySessionPreset(streamSize.sessionPreset)
            configureVideoConnection()
            beginOrientationUpdates()
            beginSessionInterruptionUpdates()
            beginAppActivationUpdates()
            DispatchQueue.global(qos: .default).async { [weak session] in
                guard let session, !session.isRunning else { return }
                session.startRunning()
            }
            return
        }
        session.beginConfiguration()
        applySessionPreset(streamSize.sessionPreset)

        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)!
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
        }
        
        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        videoOutput = output
        configureVideoConnection()
        session.commitConfiguration()
        beginOrientationUpdates()
        beginSessionInterruptionUpdates()
        beginAppActivationUpdates()
        DispatchQueue.global(qos: .default).async { [weak session] in
            session?.startRunning()
        }
    }

    private func applySessionPreset(_ preset: AVCaptureSession.Preset) {
        guard session.canSetSessionPreset(preset) else { return }
        session.sessionPreset = preset
    }

    private func beginOrientationUpdates() {
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    private func beginSessionInterruptionUpdates() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.removeObserver(self, name: AVCaptureSession.wasInterruptedNotification, object: session)
        notificationCenter.removeObserver(self, name: AVCaptureSession.interruptionEndedNotification, object: session)
        notificationCenter.removeObserver(self, name: AVCaptureSession.runtimeErrorNotification, object: session)

        notificationCenter.addObserver(
            self,
            selector: #selector(sessionWasInterrupted),
            name: AVCaptureSession.wasInterruptedNotification,
            object: session
        )

        notificationCenter.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded),
            name: AVCaptureSession.interruptionEndedNotification,
            object: session
        )

        notificationCenter.addObserver(
            self,
            selector: #selector(sessionRuntimeError),
            name: AVCaptureSession.runtimeErrorNotification,
            object: session
        )
    }

    private func beginAppActivationUpdates() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
        notificationCenter.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        if let rawReason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
           let reason = AVCaptureSession.InterruptionReason(rawValue: rawReason) {
            debugPrint("Capture session interrupted: \(reason)")
        } else {
            debugPrint("Capture session interrupted")
        }

        guard shouldAutoResume else { return }
        invalidateEncoder()
        connection?.cancel()
        connection = nil
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        debugPrint("Capture session interruption ended")
        restartStreamingAfterCaptureRecovery()
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        debugPrint("Capture session runtime error: \(String(describing: error))")

        guard shouldAutoResume else { return }
        invalidateEncoder()
        restartStreamingAfterCaptureRecovery()
    }

    @objc private func appDidBecomeActive(_ notification: Notification) {
        debugPrint("App became active; checking stream recovery")
        restartStreamingAfterCaptureRecovery()
    }

    private func restartStreamingAfterCaptureRecovery() {
        guard shouldAutoResume,
              let host = currentHost,
              let port = currentPort else { return }

        invalidateEncoder()
        setupConnection(host: host, port: port)
        applySessionPreset(currentStreamSize.sessionPreset)
        configureVideoConnection()
        beginOrientationUpdates()
        beginSessionInterruptionUpdates()
        beginAppActivationUpdates()

        DispatchQueue.global(qos: .default).async { [weak session] in
            guard let session, !session.isRunning else { return }
            session.startRunning()
        }
    }

    private func stopCaptureAndConnection() {
        DispatchQueue.global(qos: .default).async { [weak session] in
            session?.stopRunning()
        }
        invalidateEncoder()
        connection?.cancel()
        connection = nil
    }

    private func configureVideoConnection() {
        guard let videoConnection = videoOutput?.connection(with: .video) else { return }

        if videoConnection.isVideoMirroringSupported {
            videoConnection.isVideoMirrored = true
        }

        applyDeviceOrientation(to: videoConnection)
    }

    @objc private func deviceOrientationDidChange() {
        captureQueue.async { [weak self] in
            guard let self,
                  let videoConnection = self.videoOutput?.connection(with: .video) else { return }

            self.applyDeviceOrientation(to: videoConnection)
        }
    }

    private func applyDeviceOrientation(to videoConnection: AVCaptureConnection) {
        guard videoConnection.isVideoOrientationSupported,
              let videoOrientation = AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation) else { return }

        videoConnection.videoOrientation = videoOrientation
    }

    // MARK: - Encoder

    private func setupEncoder(width: Int32, height: Int32) {
        invalidateEncoder()

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
        encodedWidth = width
        encodedHeight = height
        sentConfig = false
        frameIndex = 0
    }

    private func invalidateEncoder() {
        guard let compressionSession else { return }

        VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
        encodedWidth = 0
        encodedHeight = 0
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
              let session = compressionSession(for: pixelBuffer) else { return }

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

    private func compressionSession(for pixelBuffer: CVPixelBuffer) -> VTCompressionSession? {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))

        if compressionSession == nil || width != encodedWidth || height != encodedHeight {
            setupEncoder(width: width, height: height)
        }

        return compressionSession
    }
}

private extension AVCaptureVideoOrientation {
    init?(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .portrait:
            self = .portrait
        case .portraitUpsideDown:
            self = .portraitUpsideDown
        case .landscapeLeft:
            self = .landscapeRight
        case .landscapeRight:
            self = .landscapeLeft
        default:
            return nil
        }
    }
}
