//
//  CameraStreamer.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//


@preconcurrency import AVFoundation
import UIKit
import Combine

nonisolated
final class CameraStreamer: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let captureSessionManager = CaptureSessionManager()
    private let connectionManager = ConnectionManager()
    private let encoder = H264Encoder()
    private var shouldAutoResume = false
    let isConnectedPublisher = CurrentValueSubject<Bool, Never>(false)
    
    var session: AVCaptureSession {
        captureSessionManager.session
    }

    override init() {
        super.init()
        bind()
    }
    
    private func bind() {
        bindConnectionManager()
        
        bindCaptureSessionManager()
        
        encoder.outputHandler = { [weak self] packet in
            self?.send(packet)
        }
    }
    
    private func bindConnectionManager() {
        connectionManager.onConnectionFailed = { [weak self] in
            self?.stopStreaming()
        }
        connectionManager.onConnectionChaged = { [weak self] isConnected in
            self?.isConnectedPublisher.value = isConnected
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

        let connected = connectionManager.connect(host: host, port: port)
        assert(connected)
        return preparePreview(position: position, preset: preset) && connected
    }
    
    private func encoderInvalidate() {
        encoder.invalidate()
    }
    
    func stopStreaming() {
        shouldAutoResume = false
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

        encoderInvalidate()
        _ = connectionManager.reconnectCurrent()

        try? captureSessionManager.reconfigureCurrent(delegate: self)
    }
    
    private func disconnect() {
        encoderInvalidate()
        connectionManager.disconnect()
    }

    private func stopCaptureAndConnection() {
        captureSessionManager.stopRunning()
        disconnect()
    }

    // MARK: - Capture delegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard shouldAutoResume else { return }
        encoder.encode(sampleBuffer)
    }
}
