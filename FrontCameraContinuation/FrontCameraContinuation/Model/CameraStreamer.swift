//
//  CameraStreamer.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//


@preconcurrency import AVFoundation
import UIKit
import Combine
import H264

nonisolated
final class CameraStreamer: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    typealias ConnectionStatus = ConnectionManager.Status

    private let captureSessionManager = CaptureSessionManager()
    private let connectionManager = ConnectionManager()
    private var encoder: H264Encoder!
    private let reconnectQueue = DispatchQueue(label: "camera.streamer.reconnect", qos: .utility)
    private var reconnectWorkItem: DispatchWorkItem? {
        didSet {
            guard let oldValue, oldValue !== reconnectWorkItem else {
                return
            }
            oldValue.cancel()
        }
    }
    private let sampleBufferPublisher = PassthroughSubject<CMSampleBuffer, Never>()
    private var shouldAutoResume = false
    let isConnectedPublisher = CurrentValueSubject<Bool, Never>(false)
    let connectionStatusPublisher = CurrentValueSubject<ConnectionStatus, Never>(.idle)
    let isStreamingRequestedPublisher = CurrentValueSubject<Bool, Never>(false)
    
    var session: AVCaptureSession {
        captureSessionManager.session
    }

    override init() {
        super.init()
        
        encoder = .init(
            expectedFrameRate: VirtualCameraConfiguration.frameRate,
            maxKeyInterval: VirtualCameraConfiguration.frameRate,
            outputHandler: { [weak self] data in
                self?.send(data)
            }
        )
        bind()
    }
    
    private func bind() {
        bindConnectionManager()
        
        bindCaptureSessionManager()
    }
    
    private func bindConnectionManager() {
        connectionManager.onConnectionChaged = { [weak self] isConnected in
            self?.isConnectedPublisher.value = isConnected
        }
        connectionManager.onConnectionStatusChanged = { [weak self] status in
            self?.connectionStatusPublisher.value = status
            if status == .failed {
                self?.handleConnectionFailure()
            }
        }
    }
    
    private func bindCaptureSessionManager() {
        captureSessionManager.onSessionInterrupted = { [weak self] reason in
            self?.handleSessionInterrupted(reason)
        }
        captureSessionManager.onSessionInterruptionEnded = { [weak self] in
            self?.handleSessionInterruptionEnded()
        }
        captureSessionManager.onSessionRuntimeError = { [weak self] error in
            self?.handleSessionRuntimeError(error)
        }
    }

    @discardableResult
    func preparePreview(position: AVCaptureDevice.Position, preset: AVCaptureSession.Preset) -> Bool {
        do {
            try captureSessionManager.configure(position: position, preset: preset, delegate: self)
            return true
        } catch {
            debugPrint(error)
            return false
        }
    }

    func startStreaming(host: String, port: UInt16, position: AVCaptureDevice.Position, preset: AVCaptureSession.Preset) -> Bool {
        shouldAutoResume = true
        isStreamingRequestedPublisher.value = true
        cancelPendingReconnect()

        let connected = connectionManager.connect(host: host, port: port)
        assert(connected)
        return preparePreview(position: position, preset: preset) && connected
    }
    
    private func encoderInvalidate() {
        encoder.scheduleToInvalidate()
    }
    
    func stopStreaming() {
        shouldAutoResume = false
        isStreamingRequestedPublisher.value = false
        cancelPendingReconnect()
        disconnect()
    }

    private func send(_ data: Data) {
        connectionManager.send(data)
    }

    private func handleSessionInterrupted(_ reason: AVCaptureSession.InterruptionReason?) {
        if let reason {
            debugPrint("Capture session interrupted: \(reason)")
        } else {
            debugPrint("Capture session interrupted")
        }

        guard shouldAutoResume else { return }
        disconnect()
    }

    private func handleSessionInterruptionEnded() {
        debugPrint("Capture session interruption ended")
        restartStreamingAfterCaptureRecovery()
    }

    private func handleSessionRuntimeError(_ error: Error?) {
        debugPrint("Capture session runtime error: \(String(describing: error))")
        guard shouldAutoResume else { return }
        
        stopStreaming()
    }

    private func restartStreamingAfterCaptureRecovery() {
        guard shouldAutoResume else { return }

        cancelPendingReconnect()
        encoderInvalidate()
        _ = connectionManager.reconnectCurrent()

        try? captureSessionManager.reconfigureCurrent(delegate: self)
    }
    
    private func disconnect() {
        encoderInvalidate()
        connectionManager.disconnect()
    }

    private func handleConnectionFailure() {
        guard shouldAutoResume else { return }
        encoderInvalidate()
        connectionManager.disconnectPreservingStatus()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldAutoResume else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.shouldAutoResume else {
                return
            }

            _ = self.connectionManager.reconnectCurrent()
        }
        reconnectWorkItem = workItem
        reconnectQueue.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func cancelPendingReconnect() {
        reconnectWorkItem = nil
    }

    private func stopCaptureAndConnection() {
        captureSessionManager.stopRunning()
        disconnect()
    }

    // MARK: - Capture delegate
    nonisolated
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        sampleBufferPublisher.send(sampleBuffer)
        guard shouldAutoResume, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encoder.scheduleToEncode(imageBuffer: imageBuffer)
    }
}

// MARK: - CameraStreamer.PreviewDecodedFrameProvidable
extension CameraStreamer: PreviewDecodedFrameProvidable {
    nonisolated func decodedFrameSubject() -> AnyPublisher<CMSampleBuffer, Never> {
        sampleBufferPublisher.eraseToAnyPublisher()
    }
}
