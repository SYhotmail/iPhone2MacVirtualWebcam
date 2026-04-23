//
//  CameraStreamer.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//


@preconcurrency import AVFoundation
import VideoToolbox
import Network
import UIKit
import Combine

final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()
    private var compressionSession: VTCompressionSession?
    private var connection: NWConnection? {
        didSet {
            guard let oldValue, oldValue !== connection else {
                return
            }
            oldValue.cancel()
        }
    }
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
    private var currentPreset: AVCaptureSession.Preset = .high
    private var sessionChangeWorkItem: DispatchWorkItem! {
        didSet {
            guard let oldValue, !oldValue.isCancelled, oldValue !== sessionChangeWorkItem else {
                return
            }
            oldValue.cancel()
        }
    }
    
    private var startedToGenerate = false
    
    let isConnectedPublisher = CurrentValueSubject<Bool, Never>(false)

    func preparePreview(position: AVCaptureDevice.Position, preset: AVCaptureSession.Preset) {
        currentPosition = position
        currentPreset = preset
        try? setupCamera(position: position, preset: preset)
    }

    func startStreaming(host: String, port: UInt16, position: AVCaptureDevice.Position, preset: AVCaptureSession.Preset) {
        currentHost = host
        currentPort = port
        currentPosition = position
        currentPreset = preset
        shouldAutoResume = true

        let res = setupConnection(host: host, port: port)
        assert(res)
        try? setupCamera(position: position,
                         preset: preset)
    }
    
    func stopStreaming() {
        shouldAutoResume = false
        invalidateEncoder()
        connection = nil
        isConnectedPublisher.value = false
        
        endOrientationUpdates()
        
    }

    // MARK: - TCP

    @discardableResult
    private func setupConnection(host: String, port: UInt16) -> Bool {
        guard let p = NWEndpoint.Port(rawValue: port) else {
            return false
        }

        connection = nil
        
        let endpoint = NWEndpoint.Host(host)
        let connection = NWConnection(host: endpoint, port: p, using: .tcp)
        
        // !!! New State failed(POSIXErrorCode(rawValue: 54): Connection reset by peer)
        connection.stateUpdateHandler = { [weak self] newState in
            debugPrint("!!! New State \(newState)")
            let isReady: Bool
            if case .ready = newState {
                isReady = true
            } else {
                isReady = false
                if case .failed = newState { // socket closed etc..
                    // if error.errorCode == 54 || error.errorCode == 57
                    // self?.
                    self?.stopStreaming()
                }
            }
            self?.isConnectedPublisher.value = isReady
        }
        connection.pathUpdateHandler = { newPath in
            debugPrint("!!! New Path \(newPath.debugDescription)")
        }
        
        connection.viabilityUpdateHandler = { isViable in
            debugPrint("!!! isViable \(isViable)") // data can be send and received..
        }
        
        connection.betterPathUpdateHandler = { newHasBetterPath in
            debugPrint("!!! newHasBetterPath \(newHasBetterPath)")
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
            let disconnectedSocket = error.errorCode == 57 || error.errorCode == 54 // closed connection...
        }))
    }

    // MARK: - Camera
    
    private func configureSession(preset: AVCaptureSession.Preset,
                                  inBatch: Bool,
                                  position: AVCaptureDevice.Position? = nil) throws {
        // debugPrint("!!! \(#function) inBatch \(inBatch) position \(position, default: "no position")")
        if inBatch {
            sessionChangeWorkItem = nil
            session.beginConfiguration()
        }
        
        applySessionPreset(preset)
        
        if let position {
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) ?? AVCaptureDevice.default(for: .video)
            let input = try device.flatMap { try AVCaptureDeviceInput(device: $0) }
            session.inputs.forEach { session.removeInput($0) }
            if let input, session.canAddInput(input) {
                session.addInput(input)
            }
            
            let output = AVCaptureVideoDataOutput()
            output.setSampleBufferDelegate(self, queue: captureQueue)
            session.outputs.forEach { session.removeOutput($0) }
            
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            videoOutput = output
        }
        configureVideoConnection()
        
        if inBatch {
            session.commitConfiguration()
        }
        
        beginOrientationUpdates()
        beginSessionInterruptionUpdates()
        beginAppActivationUpdates()
        
        scheduleSessionStart()
    }
    
    private func scheduleSessionStart() {
        sessionChangeWorkItem = .init(flags: .inheritQoS) { [weak session] in
            guard let session, !session.isRunning else { return }
#if !targetEnvironment(simulator)
            session.startRunning()
#endif
        }
        
        DispatchQueue.global(qos: .default).async(execute: sessionChangeWorkItem)
    }

    private func setupCamera(position: AVCaptureDevice.Position,
                             preset: AVCaptureSession.Preset) throws {
        // If we already have an input with the same device position, don't pass a new position
        let hasInputWithSamePosition = session.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .contains { $0.device.position == position }
        
        let noInputWithSamePosition = !hasInputWithSamePosition
        
        try configureSession(preset: preset,
                             inBatch: noInputWithSamePosition,
                             position: noInputWithSamePosition ? position : nil)
    }

    private func applySessionPreset(_ preset: AVCaptureSession.Preset) {
        guard session.sessionPreset != preset, session.canSetSessionPreset(preset) else { return }
        session.sessionPreset = preset
    }

    private func beginOrientationUpdates() {
        let name = UIDevice.orientationDidChangeNotification
        let notificationCenter = removeNotificationCenterObserver(name)
        
        notificationCenter.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: name,
            object: nil
        )
        
        guard !startedToGenerate else {
            return
        }
        
        if !UIDevice.current.isGeneratingDeviceOrientationNotifications {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            startedToGenerate = UIDevice.current.isGeneratingDeviceOrientationNotifications
        }
    }
    
    private func endOrientationUpdates() {
        let name = UIDevice.orientationDidChangeNotification
        removeNotificationCenterObserver(name)
        
        guard startedToGenerate else {
            return
        }
        if UIDevice.current.isGeneratingDeviceOrientationNotifications {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            startedToGenerate = UIDevice.current.isGeneratingDeviceOrientationNotifications
        }
    }

    private func beginSessionInterruptionUpdates() {
        let notificationCenter = removeNotificationCenterObserver(AVCaptureSession.wasInterruptedNotification, object: session)
        removeNotificationCenterObserver(AVCaptureSession.interruptionEndedNotification, object: session)
        removeNotificationCenterObserver(AVCaptureSession.runtimeErrorNotification, object: session)

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
        let name = UIApplication.didBecomeActiveNotification
        let notificationCenter = removeNotificationCenterObserver(name)
        notificationCenter.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: name,
            object: nil
        )
    }
    
    @discardableResult
    private func removeNotificationCenterObserver(_ name: NSNotification.Name, object: Any? = nil) -> NotificationCenter {
        let notificationCenter = NotificationCenter.default
        notificationCenter.removeObserver(self, name: name, object: object)
        return notificationCenter
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
        connection = nil
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        debugPrint("Capture session interruption ended")
        restartStreamingAfterCaptureRecovery()
    }
    
    // !!! Error: The operation couldn’t be completed. (Network.NWError error 57 - Socket is not connected)"

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
    
        try? setupCamera(position: currentPosition,
                         preset: currentPreset)
    }

    private func stopCaptureAndConnection() {
        sessionChangeWorkItem = .init(flags: .enforceQoS) { [weak session] in
            guard let session, session.isRunning else { return }
            session.stopRunning()
        }
        DispatchQueue.global(qos: .default).async(execute: sessionChangeWorkItem)
        
        invalidateEncoder()
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
                             value: 30 as CFTypeRef)

        VTSessionSetProperty(compressionSession,
                             key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Baseline_AutoLevel)

        VTCompressionSessionPrepareToEncodeFrames(compressionSession)
        
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

        guard shouldAutoResume, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
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

