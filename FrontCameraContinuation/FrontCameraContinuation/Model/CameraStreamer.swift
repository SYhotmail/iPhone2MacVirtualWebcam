//
//  CameraStreamer.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//


@preconcurrency import AVFoundation
import UIKit
import Combine

final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let captureSessionManager = CaptureSessionManager()
    private let connectionManager = ConnectionManager()
    private let encoder = H264Encoder()
    private var shouldAutoResume = false

    var session: AVCaptureSession {
        captureSessionManager.session
    }

    var isConnectedPublisher: CurrentValueSubject<Bool, Never> {
        connectionManager.isConnectedPublisher
    }

    override init() {
        super.init()
        connectionManager.onConnectionFailed = { [weak self] in
            self?.stopStreaming()
        }
        captureSessionManager.onSessionInterrupted = { [weak self] reason in
            self?.handleSessionInterrupted(reason)
        }
        captureSessionManager.onSessionInterruptionEnded = { [weak self] in
            self?.handleSessionInterruptionEnded()
        }
        captureSessionManager.onSessionRuntimeError = { [weak self] error in
            self?.handleSessionRuntimeError(error)
        }
        
        encoder.outputHandler = { [weak self] packet in
            self?.send(packet)
        }
    }

    func preparePreview(position: AVCaptureDevice.Position, preset: AVCaptureSession.Preset) {
        beginAppActivationUpdates()
        try? captureSessionManager.configure(position: position, preset: preset, delegate: self)
    }

    func startStreaming(host: String, port: UInt16, position: AVCaptureDevice.Position, preset: AVCaptureSession.Preset) {
        shouldAutoResume = true

        let res = connectionManager.connect(host: host, port: port)
        assert(res)
        beginAppActivationUpdates()
        try? captureSessionManager.configure(position: position, preset: preset, delegate: self)
    }
    
    private func encoderInvalidate() {
        encoder.invalidate()
    }
    
    func stopStreaming() {
        shouldAutoResume = false
        encoderInvalidate()
        connectionManager.disconnect()
    }

    private func send(_ data: Data) {
        connectionManager.sendPacketized(data)
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

    private func handleSessionInterrupted(_ reason: AVCaptureSession.InterruptionReason?) {
        if let reason {
            debugPrint("Capture session interrupted: \(reason)")
        } else {
            debugPrint("Capture session interrupted")
        }

        guard shouldAutoResume else { return }
        encoderInvalidate()
        connectionManager.disconnect()
    }

    private func handleSessionInterruptionEnded() {
        debugPrint("Capture session interruption ended")
        restartStreamingAfterCaptureRecovery()
    }

    private func handleSessionRuntimeError(_ error: Error?) {
        debugPrint("Capture session runtime error: \(String(describing: error))")

        guard shouldAutoResume else { return }
        encoderInvalidate()
        restartStreamingAfterCaptureRecovery()
    }

    @objc private func appDidBecomeActive(_ notification: Notification) { // TODO: think what to do here?
        debugPrint("App became active; checking stream recovery")
        restartStreamingAfterCaptureRecovery()
    }

    private func restartStreamingAfterCaptureRecovery() {
        guard shouldAutoResume else { return }

        encoderInvalidate()
        _ = connectionManager.reconnectCurrent()

        try? captureSessionManager.reconfigureCurrent(delegate: self)
    }

    private func stopCaptureAndConnection() {
        captureSessionManager.stopRunning()
        encoderInvalidate()
        connectionManager.disconnect()
    }

    // MARK: - Capture delegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard shouldAutoResume else { return }
        encoder.encode(sampleBuffer)
    }
}
