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
            return "Default (High Quality)"
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

@MainActor
final class StreamManager: ObservableObject {
    @Published private(set) var isStreaming = false

    private let cameraStreamer = CameraStreamer()
    private var connectionCancellable: AnyCancellable?

    init() {
        connectionCancellable = cameraStreamer.isConnectedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                self?.isStreaming = isConnected
            }
    }

    var previewSession: AVCaptureSession {
        cameraStreamer.session
    }

    func preparePreview(streamSize: StreamSize) {
        cameraStreamer.preparePreview(position: .front, preset: streamSize.sessionPreset)
    }

    func startStreaming(host: String, port: UInt16, streamSize: StreamSize) {
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

    func supportedCameraSessionPresets() -> [StreamSize] {
        StreamSize.allCases.filter { cameraStreamer.session.canSetSessionPreset($0.sessionPreset) }
    }
}
