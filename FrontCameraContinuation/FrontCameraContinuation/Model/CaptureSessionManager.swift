@preconcurrency import AVFoundation
import Combine
import UIKit
import OSLog

final class CaptureSessionManager {
    let session = AVCaptureSession()
    
    var onSessionInterrupted: ((AVCaptureSession.InterruptionReason?) -> Void)?
    var onSessionInterruptionEnded: (() -> Void)?
    var onSessionRuntimeError: ((Error?) -> Void)?

    private let captureQueue: DispatchQueue
    private var videoOutput: AVCaptureVideoDataOutput?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var currentPosition: AVCaptureDevice.Position = .front
    private var sessionChangeWorkItem: DispatchWorkItem? {
        didSet {
            guard let oldValue, !oldValue.isCancelled, oldValue !== sessionChangeWorkItem else {
                return
            }
            oldValue.cancel()
        }
    }
    
    private var notificationCancellables = Set<AnyCancellable>(minimumCapacity: 3)
    private var orientationCancellable: AnyCancellable? {
        didSet {
            guard let oldValue, oldValue !== orientationCancellable else {
                return
            }
            oldValue.cancel()
        }
    }
    
    private let logger: Logger?
    
    init(logger: Logger? = { Bundle.main.bundleIdentifier.flatMap { .init(subsystem: $0, category: "capture.session.manager") } }()) {
        captureQueue = .init(label: "camera.session.manager", qos: .userInitiated)
        self.logger = logger
    }

    private func setSampleBufferDelegate(_ delegate: AVCaptureVideoDataOutputSampleBufferDelegate) {
        videoOutput?.setSampleBufferDelegate(delegate, queue: captureQueue)
    }

    func configure(position: AVCaptureDevice.Position,
                   preset: AVCaptureSession.Preset,
                   delegate: AVCaptureVideoDataOutputSampleBufferDelegate,
                   startRunning start: Bool = true) throws {
        currentPosition = position

        let hasInputWithSamePosition = session.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .contains { $0.device.position == position }
        
        let canSetPreset = session.canSetSessionPreset(preset) && session.sessionPreset != preset
        
        let requiresInputRebuild = !hasInputWithSamePosition
        let changeConfiguration = requiresInputRebuild || canSetPreset
        if changeConfiguration {
            sessionChangeWorkItem = nil
            session.beginConfiguration()
        }

        if canSetPreset {
            session.sessionPreset = preset
        }

        if requiresInputRebuild {
            do {
                try rebuildGraph(for: position, delegate: delegate)
            }
            catch {
                session.commitConfiguration()
                throw error
            }
        } else {
            setSampleBufferDelegate(delegate)
        }

        configureVideoConnection()

        if changeConfiguration {
            session.commitConfiguration()
        }
        
        if start {
            startRunning()
        }
    }

    func reconfigureCurrent(delegate: AVCaptureVideoDataOutputSampleBufferDelegate) throws {
        try configure(position: currentPosition,
                      preset: session.sessionPreset,
                      delegate: delegate)
    }
    
    private func startRunning() {
        beginSessionNotifications()
        beginOrientationUpdates()
        scheduleChangeSession(shouldRun: true)
    }

    func stopRunning() {
        orientationCancellable = nil
        notificationCancellables.removeAll(keepingCapacity: true)
        scheduleChangeSession(shouldRun: false)
    }

    private func rebuildGraph(for position: AVCaptureDevice.Position,
                              delegate: AVCaptureVideoDataOutputSampleBufferDelegate) throws {
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) ?? AVCaptureDevice.default(for: .video)
        let input = try device.flatMap { try AVCaptureDeviceInput(device: $0) }
        guard let input, let device else {
            throw NSError(domain: "custom", code: .min)
        }
        session.inputs.forEach { session.removeInput($0) }
        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureVideoDataOutput()
        assert(output.alwaysDiscardsLateVideoFrames == true)
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(delegate, queue: captureQueue)
        session.outputs.forEach { session.removeOutput($0) }

        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        videoOutput = output
        configureRotationCoordinator(for: device)
    }

    private func scheduleChangeSession(shouldRun: Bool) {
        let sessionChangeWorkItem = DispatchWorkItem(flags: .inheritQoS) { [weak session] in
            guard let session else { return }
#if !targetEnvironment(simulator)
            if shouldRun {
                if !session.isRunning {
                    session.startRunning()
                }
            } else if session.isRunning {
                session.stopRunning()
            }
#endif
        }
        self.sessionChangeWorkItem = sessionChangeWorkItem
        DispatchQueue.global(qos: .userInitiated).async(execute: sessionChangeWorkItem)
    }

    private func configureVideoConnection() {
        guard let videoConnection = videoOutput?.connection(with: .video) else { return }

        if videoConnection.isVideoMirroringSupported, !videoConnection.isVideoMirrored {
            videoConnection.isVideoMirrored = true
        }

        applyRotationAngle(to: videoConnection)
    }

    private func beginOrientationUpdates() {
        orientationCancellable = rotationCoordinator?.publisher(for: \.videoRotationAngleForHorizonLevelCapture)
            .sink { [weak self] _ in
                self?.updateVideoConnectionRotation()
            }
        if rotationCoordinator != nil {
            updateVideoConnectionRotation()
        }
    }

    private func beginSessionNotifications() {
        let notificationCenter = NotificationCenter.default
        notificationCancellables.removeAll(keepingCapacity: true)
        
        notificationCenter.publisher(for: AVCaptureSession.wasInterruptedNotification, object: session)
            .sink { [weak self] notification in
                let rawReason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
                let reason = rawReason.flatMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
                self?.logger?.debug("Session was interupped \(reason?.rawValue ?? -1)")
                self?.onSessionInterrupted?(reason)
            }
            .store(in: &notificationCancellables)

        notificationCenter.publisher(for: AVCaptureSession.interruptionEndedNotification, object: session)
            .sink { [weak self] _ in
                self?.logger?.debug("Session interruptioned ended")
                self?.onSessionInterruptionEnded?()
            }
            .store(in: &notificationCancellables)

        notificationCenter.publisher(for: AVCaptureSession.runtimeErrorNotification, object: session)
            .sink { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                self?.logger?.debug("Session runtime error error \(error?.localizedDescription ?? "")")
                self?.onSessionRuntimeError?(error)
            }
            .store(in: &notificationCancellables)
    }

    private func configureRotationCoordinator(for device: AVCaptureDevice) {
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
    }

    private func updateVideoConnectionRotation() {
        captureQueue.async { [weak self] in
            guard let self,
                  let videoConnection = self.videoOutput?.connection(with: .video) else { return }

            self.applyRotationAngle(to: videoConnection)
        }
    }

    private func applyRotationAngle(to videoConnection: AVCaptureConnection) {
        guard let rotationCoordinator else { return }
        let angle = rotationCoordinator.videoRotationAngleForHorizonLevelCapture
        guard videoConnection.isVideoRotationAngleSupported(angle), videoConnection.videoRotationAngle != angle else { return }
        videoConnection.videoRotationAngle = angle
    }
}
