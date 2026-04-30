import CoreMedia

enum VirtualCameraConfiguration {
    static let extensionBundleIdentifier = "by.sy.TCPServer.VirtualCameraExtension"
    static let deviceName = "Remote Camera"
    static let manufacturerName = "FrontCameraContinuation"
    static let modelName = "Virtual Camera"
    static let streamWidth = 1280
    static let streamHeight = 720
    static let frameRate: Int32 = 30
    static let pixelFormat = kCVPixelFormatType_32BGRA

    static var frameDuration: CMTime {
        CMTime(value: 1, timescale: frameRate)
    }
}
