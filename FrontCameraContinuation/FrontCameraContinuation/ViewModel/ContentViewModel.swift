import SwiftUI
import AVFoundation
import Combine
#if os(iOS)
import UIKit
#endif

@Observable
final class ContentViewModel {
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
    
    private var connectionCancellable: AnyCancellable?
    private(set)var isPreviewVisible = false
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
        streamSize = defaults.object(forKey: Constants.streamSize) != nil ? StreamSize(rawValue: defaults.integer(forKey: Constants.streamSize)) ?? .full : .full
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

    // MARK: - Actions

    func togglePreviewVisibility() {
        if !isPreviewVisible, !isStreaming {
            preparePreview()
        }
        isPreviewVisible.toggle()
    }
    
    func toggleStreaming() {
        if isStreaming {
            stopStreaming()
        } else {
            startStreaming()
        }
    }

    func startStreaming() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = UInt16(port) ?? Constants.defaultPort
        
        isStreaming = cameraStreamer.startStreaming(
            host: trimmedHost,
            port: portValue,
            position: cameraPosition.avPosition,
            preset: streamSize.sessionPreset
        )
    }

    func stopStreaming() {
        cameraStreamer.stopStreaming()
        isStreaming = false
    }

    private func bind() {
        connectionCancellable = cameraStreamer.isConnectedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                self?.isStreaming = isConnected
            }
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
}
