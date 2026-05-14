import SwiftUI
import AVFoundation
import Combine
#if os(iOS)
import UIKit
#endif

@Observable
final class ContentViewModel {
    enum StreamStatus: Equatable {
        case idle
        case connecting
        case waitingForReceiver
        case streaming
        case attentionNeeded
    }

    enum Constants {
        static let hostKey = "host"
        static let portKey = "port"
        static let streamSize = "streamSize"
        static let cameraPosition = "cameraPosition"
        static let defaultHost = "192.168.1.10"
        static let defaultPortString = "9999"
        static let defaultPort: UInt16 = 9999
    }

    // Inputs persisted by the view
    var host: String {
        didSet {
            guard oldValue != host else {
                return
            }
            defaults.set(host, forKey: Constants.hostKey)
        }
    }
    
    var port: String {
        didSet {
            guard oldValue != port else {
                return
            }
            defaults.set(port, forKey: Constants.portKey)
        }
    }

    // UI state
    var streamSize: StreamSize {
        didSet {
            guard oldValue != streamSize else {
                return
            }
            defaults.set(streamSize.rawValue, forKey: Constants.streamSize)
            preparePreview()
        }
    }
    
    var cameraPosition: CameraPosition {
        didSet {
            guard oldValue != cameraPosition else {
                return
            }
            defaults.set(cameraPosition.rawValue, forKey: Constants.cameraPosition)
            preparePreview()
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    private(set)var isPreviewVisible = false
    private(set) var isStreamingRequested = false
    private(set) var streamStatus: StreamStatus = .idle
    private(set)var isStreaming = false {
        didSet {
            guard oldValue != isStreaming else {
                return
            }
            Self.changeIdleTimer(isStreaming)
        }
    }
    
    init(cameraStreamer: CameraStreamer = .init(), defaults: UserDefaults = .standard) {
        self.cameraStreamer = cameraStreamer
        self.defaults = defaults
        host = defaults.string(forKey: Constants.hostKey) ?? Constants.defaultHost
        port = defaults.string(forKey: Constants.portKey) ?? Constants.defaultPortString
        streamSize = defaults.object(forKey: Constants.streamSize) != nil ? StreamSize(rawValue: defaults.integer(forKey: Constants.streamSize)) ?? .hd720 : .hd720
        cameraPosition = defaults.object(forKey: Constants.cameraPosition) != nil ? CameraPosition(rawValue: defaults.integer(forKey: Constants.cameraPosition)) ?? .front : .front
        bind()
    }

    // Streaming backend
    let cameraStreamer: CameraStreamer
    let defaults: UserDefaults

    var previewSession: AVCaptureSession {
        cameraStreamer.session
    }
    
    private func preparePreview() {
        cameraStreamer.preparePreview(position: cameraPosition.avPosition,
                                      preset: streamSize.sessionPreset)
    }
    
    var isStreamingText: String {
        switch streamStatus {
        case .idle:
            return "Camera is warmed up so you can frame the shot before sending it to your Mac."
        case .connecting:
            return "Trying to reach your Mac now. Keep the app open until the connection turns live."
        case .waitingForReceiver:
            return "The Mac receiver is offline right now. This iPhone will keep capturing and retry automatically until the Mac app is ready."
        case .streaming:
            return "Sending the camera feed to your Mac right now."
        case .attentionNeeded:
            return "We lost the connection before the stream went live. Check the Mac address, port, and receiver status, then try again."
        }
    }

    var statusTitle: String {
        switch streamStatus {
        case .idle:
            return "Ready"
        case .connecting:
            return "Connecting"
        case .waitingForReceiver:
            return "Waiting for Mac"
        case .streaming:
            return "Live"
        case .attentionNeeded:
            return "Check Connection"
        }
    }

    var statusDetail: String {
        switch streamStatus {
        case .idle:
            return "Preview is available and the stream is not running."
        case .connecting:
            return "Trying to connect to your Mac receiver."
        case .waitingForReceiver:
            return "The receiver is not accepting connections yet. We will keep retrying in the background."
        case .streaming:
            return "Your Mac is receiving the camera feed."
        case .attentionNeeded:
            return "The Mac receiver did not accept the stream."
        }
    }

    var primaryActionTitle: String {
        switch streamStatus {
        case .connecting, .waitingForReceiver, .streaming:
            return "Stop Stream"
        case .attentionNeeded:
            return "Retry Stream"
        case .idle:
            return "Start Stream"
        }
    }

    var primaryActionSymbol: String {
        switch streamStatus {
        case .connecting, .waitingForReceiver, .streaming:
            return "stop.fill"
        case .attentionNeeded:
            return "arrow.clockwise"
        case .idle:
            return "bolt.fill"
        }
    }

    // MARK: - Actions

    func togglePreviewVisibility() {
        if !isPreviewVisible, !isStreaming {
            preparePreview()
        }
        isPreviewVisible.toggle()
    }
    
    func toggleStreaming() {
        if isStreamingRequested {
            stopStreaming()
        } else {
            startStreaming()
        }
    }

    func startStreaming() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = UInt16(port) ?? Constants.defaultPort

        isStreamingRequested = true
        streamStatus = .connecting
        let didStart = cameraStreamer.startStreaming(
            host: trimmedHost,
            port: portValue,
            position: cameraPosition.avPosition,
            preset: streamSize.sessionPreset
        )

        if !didStart {
            isStreamingRequested = false
            isStreaming = false
            streamStatus = .attentionNeeded
        }
    }

    func stopStreaming() {
        cameraStreamer.stopStreaming()
        isStreamingRequested = false
        isStreaming = false
        streamStatus = .idle
    }

    private func bind() {
        cameraStreamer.isConnectedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                self?.isStreaming = isConnected
            }
            .store(in: &cancellables)

        cameraStreamer.connectionStatusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.applyConnectionStatus(status)
            }
            .store(in: &cancellables)

        cameraStreamer.isStreamingRequestedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRequested in
                self?.isStreamingRequested = isRequested
            }
            .store(in: &cancellables)
    }

    func supportedCameraStreamSizes() -> [StreamSize] {
        StreamSize.allCases.filter { cameraStreamer.session.canSetSessionPreset($0.sessionPreset) }
    }
    
    func toggleCameraPosition() {
        switch cameraPosition {
        case .front:
            cameraPosition = .back
        case .back:
            cameraPosition = .front
        }
    }
    

    private static func changeIdleTimer(_ isIdleTimerDisabled: Bool) {
#if os(iOS)
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = isIdleTimerDisabled
        }
#endif
    }

    private func applyConnectionStatus(_ status: CameraStreamer.ConnectionStatus) {
        switch status {
        case .idle:
            if !isStreamingRequested && !isStreaming {
                streamStatus = .idle
            }
        case .connecting:
            if streamStatus != .waitingForReceiver {
                streamStatus = .connecting
            }
        case .connected:
            streamStatus = .streaming
        case .failed:
            isStreaming = false
            streamStatus = isStreamingRequested ? .waitingForReceiver : .attentionNeeded
        }
    }
}
