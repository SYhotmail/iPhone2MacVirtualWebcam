import Foundation
import CoreImage
import CoreMedia
import CoreVideo

private func makeVirtualCameraPixelBuffer(from imageBuffer: CVImageBuffer, context: CIContext) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferWidthKey: VirtualCameraConfiguration.streamWidth,
        kCVPixelBufferHeightKey: VirtualCameraConfiguration.streamHeight,
        kCVPixelBufferPixelFormatTypeKey: VirtualCameraConfiguration.pixelFormat,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
    ]

    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        VirtualCameraConfiguration.streamWidth,
        VirtualCameraConfiguration.streamHeight,
        VirtualCameraConfiguration.pixelFormat,
        attributes as CFDictionary,
        &pixelBuffer
    )

    guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

    let image = CIImage(cvPixelBuffer: imageBuffer)
    let targetRect = CGRect(x: 0, y: 0, width: VirtualCameraConfiguration.streamWidth, height: VirtualCameraConfiguration.streamHeight)
    let scale = min(targetRect.width / image.extent.width, targetRect.height / image.extent.height)
    let scaledSize = CGSize(width: image.extent.width * scale, height: image.extent.height * scale)
    let origin = CGPoint(
        x: (targetRect.width - scaledSize.width) / 2,
        y: (targetRect.height - scaledSize.height) / 2
    )

    let scaledImage = image
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    let backgroundImage = CIImage(color: .black).cropped(to: targetRect)
    let compositedImage = scaledImage.composited(over: backgroundImage)

    context.render(compositedImage, to: pixelBuffer, bounds: targetRect, colorSpace: CGColorSpaceCreateDeviceRGB())
    return pixelBuffer
}

final class VirtualCameraSampleBufferConverter {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func makeSampleBuffer(from sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let pixelBuffer = makeVirtualCameraPixelBuffer(from: imageBuffer, context: context) else {
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
