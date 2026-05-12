import CoreMedia

nonisolated
enum VirtualCameraConfiguration {
    static let deviceName = "Remote Camera"
    static let manufacturerName = "Siarhei Yakushevich"
    static let modelName = "Virtual Camera"
    static let streamWidth = 1280
    static let streamHeight = 720
    static let pixelFormat = kCVPixelFormatType_32BGRA

    static let frameRate = 30
    
    static var frameDuration: CMTime {
        guard frameRate > 0 else {
            return CMTime.invalid
        }
        return CMTime(value: 1, timescale: CMTimeScale(frameRate))
    }
}
