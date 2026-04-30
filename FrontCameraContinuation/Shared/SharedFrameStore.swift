import Foundation
import CoreImage
import CoreMedia
import CoreVideo


struct VirtualCameraSampleBufferConverter {
    private let context = CIContext(options: [.cacheIntermediates: false])
    
    private static func makeVirtualCameraPixelBuffer(from imageBuffer: CVImageBuffer, context: CIContext) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let streamWidth = VirtualCameraConfiguration.streamWidth
        let streamHeight = VirtualCameraConfiguration.streamHeight
        let pixelFormat = VirtualCameraConfiguration.pixelFormat
        
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: streamWidth,
            kCVPixelBufferHeightKey: streamHeight,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        // TODO: use pixel pool
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            streamWidth,
            streamHeight,
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        let image = CIImage(cvPixelBuffer: imageBuffer)
        let targetRect = CGRect(x: 0, y: 0, width: streamWidth, height: streamHeight)
        let scale = min(targetRect.width / image.extent.width, targetRect.height / image.extent.height)
        let scaledSize = CGSize(width: image.extent.width * scale, height: image.extent.height * scale)
        let origin = CGPoint(
            x: (targetRect.width - scaledSize.width) / 2,
            y: (targetRect.height - scaledSize.height) / 2
        )

        let scaledImage = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        // could be composited here, etc..
        //let backgroundImage = CIImage(color: .black).cropped(to: targetRect)
        let compositedImage = scaledImage.cropped(to: targetRect) //.composited(over: backgroundImage)

        context.render(compositedImage, to: pixelBuffer, bounds: targetRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        return pixelBuffer
    }

    func makeSampleBuffer(from sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let pixelBuffer = Self.makeVirtualCameraPixelBuffer(from: imageBuffer, context: context) else {
            return nil
        }

        var formatDescription: CMFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else { return nil }

        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        var timingInfo = CMSampleTimingInfo(
            duration: VirtualCameraConfiguration.frameDuration,
            presentationTimeStamp: hostTime,
            decodeTimeStamp: .invalid
        )

        var outputSampleBuffer: CMSampleBuffer?
        let sampleBufferStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &outputSampleBuffer
        )

        guard sampleBufferStatus == noErr else { return nil }
        return outputSampleBuffer
    }
}
