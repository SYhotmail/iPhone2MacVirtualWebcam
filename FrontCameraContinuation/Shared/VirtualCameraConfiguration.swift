import CoreMedia

enum VirtualCameraConfiguration {
    static let extensionBundleIdentifier = "by.sy.TCPServer.VirtualCameraExtension" // "by.sy.TCPServer.TempBro"
    static let deviceName = "Remote Camera"
    static let manufacturerName = "FrontCameraContinuation"
    static let modelName = "Virtual Camera"
    static let streamWidth = 1920 //1280
    static let streamHeight = 1080 //720
    static let frameRate: Int32 = 60 //30
    static let pixelFormat = kCVPixelFormatType_32BGRA

    static var frameDuration: CMTime {
        CMTime(value: 1, timescale: frameRate)
    }
}
