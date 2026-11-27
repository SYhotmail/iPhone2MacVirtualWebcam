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
import Transport

nonisolated
final class CameraStreamer: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    typealias ConnectionStatus = FrameStreamClient.Status

    private let captureSessionManager = CaptureSessionManager()
    private let streamClient: FrameStreamClient
    private var encoder: VideoEncoder!
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
    private struct EncodedPacket {
        let data: Data
        let isKeyframe: Bool
    }
    /// Encoded packets in encoder order; one consumer sends them so frame order is kept on the wire.
    private let outgoingPackets: AsyncStream<EncodedPacket>.Continuation
    
    var session: AVCaptureSession {
        captureSessionManager.session
    }

    init(tlsConfiguration: TLSConfiguration = .default) throws {
        let streamClient = FrameStreamClient(transport: tlsConfiguration.transport)
        self.streamClient = streamClient
        let (packets, continuation) = AsyncStream.makeStream(of: EncodedPacket.self, bufferingPolicy: .unbounded)
        self.outgoingPackets = continuation
        super.init()
        Task { [weak self] in
            for await packet in packets {
                guard let self, !Task.isCancelled else {
                    return
                }
                await self.streamClient.send(packet.data, isKeyframe: packet.isKeyframe)
            }
        }
        
        encoder = .init(
            expectedFrameRate: VirtualCameraConfiguration.frameRate,
            maxKeyInterval: VirtualCameraConfiguration.frameRate,
            outputHandler: { [weak self] data, isKeyframe in
                self?.send(data, isKeyframe: isKeyframe)
            }
        )
        bind()
    }
    
    deinit {
        outgoingPackets.finish()
    }

    private func bind() {
        bindConnectionManager()
        
        bindCaptureSessionManager()
    }
    
    private func bindConnectionManager() {
        Task { [weak self] in
            guard let self else {
                return
            }

            await streamClient.setConnectivityChangedHandler { [weak self] isConnected in
                self?.isConnectedPublisher.value = isConnected
            }
            await streamClient.setKeyframeRequestHandler { [weak self] in
                self?.encoder.scheduleToForceKeyframe()
            }
            await streamClient.setStatusChangedHandler { [weak self] status in
                self?.connectionStatusPublisher.value = status
                if status == .failed {
                    self?.handleConnectionFailure()
                }
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

    func startStreaming(to destination: FrameStreamClient.Destination, position: AVCaptureDevice.Position, preset: AVCaptureSession.Preset) -> Bool {
        shouldAutoResume = true
        isStreamingRequestedPublisher.value = true
        cancelPendingReconnect()

        Task {
            await streamClient.connect(to: destination)
        }
        return preparePreview(position: position, preset: preset)
    }
    
    /// Releases the camera so another capture client (the pairing scanner) can use it.
    func stopCapture() {
        captureSessionManager.stopRunning()
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

    private func send(_ data: Data, isKeyframe: Bool) {
        outgoingPackets.yield(EncodedPacket(data: data, isKeyframe: isKeyframe))
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
    
    private func scheduleToReconnect() {
        Task {
            _ = await streamClient.reconnect()
        }
    }

    private func restartStreamingAfterCaptureRecovery() {
        guard shouldAutoResume else { return }

        cancelPendingReconnect()
        encoderInvalidate()
        scheduleToReconnect()

        try? captureSessionManager.reconfigureCurrent(delegate: self)
    }
    
    private func disconnect() {
        encoderInvalidate()
        Task {
            await streamClient.disconnect()
        }
    }

    private func handleConnectionFailure() {
        guard shouldAutoResume else { return }
        encoderInvalidate()
        Task {
            await streamClient.disconnectPreservingStatus()
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldAutoResume else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.shouldAutoResume else {
                return
            }

            scheduleToReconnect()
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
