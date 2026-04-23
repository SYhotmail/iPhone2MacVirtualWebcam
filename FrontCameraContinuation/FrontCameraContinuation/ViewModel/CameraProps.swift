import AVFoundation
import Combine

// MARK: - StreamSize
enum StreamSize: Int, CaseIterable {
    case full
    case hd720
    case hd1920x1080
    case vga
    case medium
    case low
}

extension StreamSize: Identifiable {

    var id: Int { rawValue }

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

// MARK: - CameraPosition

enum CameraPosition: Int, CaseIterable {
    case front
    case back
}

extension CameraPosition: Identifiable {

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .front:
            return "Front"
        case .back:
            return "Back"
        }
    }

    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .front:
            return .front
        case .back:
            return .back
        }
    }
}
