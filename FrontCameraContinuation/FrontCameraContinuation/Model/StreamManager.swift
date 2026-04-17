//
//  StreamManager.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 17/04/2026.
//

import AVFoundation
import Combine

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
    
    var isConnectedPublisher: AnyPublisher<Bool, Never> {
        cameraStreamer.isConnectedPublisher.receive(on: DispatchQueue.main).eraseToAnyPublisher()
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
