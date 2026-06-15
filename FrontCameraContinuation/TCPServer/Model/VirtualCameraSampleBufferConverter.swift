import Foundation
import CoreMedia
import CoreVideo
import Metal


nonisolated
struct VirtualCameraSampleBufferConverter {
    struct Configuration {
        let streamWidth: Int
        var streamHeight: Int
        let pixelFormat: OSType
        let frameDuration: CMTime

        init(streamWidth: Int,
             streamHeight: Int,
             pixelFormat: OSType,
             frameDuration: CMTime) {
            self.streamWidth = streamWidth
            self.streamHeight = streamHeight
            self.pixelFormat = pixelFormat
            self.frameDuration = frameDuration
        }

        init() {
            self.init(streamWidth: VirtualCameraConfiguration.streamWidth,
                      streamHeight: VirtualCameraConfiguration.streamHeight,
                      pixelFormat: VirtualCameraConfiguration.pixelFormat,
                      frameDuration: VirtualCameraConfiguration.frameDuration)
        }
    }

    private struct ScaleParams {
        var scale: SIMD2<Float>
        var offset: SIMD2<Float>
    }

    let configuration: Configuration
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLComputePipelineState?
    private let textureCache: CVMetalTextureCache?
    private var pixelBufferPool: CVPixelBufferPool?

    init(configuration: Configuration = .init()) {
        self.configuration = configuration

        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()

        let library = try? device?.makeDefaultLibrary(bundle: .main)
        var pipelineState: MTLComputePipelineState?
        if let function = library?.makeFunction(name: "scaleAndCenter") {
            pipelineState = try? device?.makeComputePipelineState(function: function)
        }
        self.pipelineState = pipelineState

        var textureCache: CVMetalTextureCache?
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
        self.textureCache = textureCache

        self.pixelBufferPool = Self.createPixelBufferPool(configuration: configuration)
    }

    private static func createPixelBufferPool(configuration: Configuration) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: configuration.streamWidth,
            kCVPixelBufferHeightKey: configuration.streamHeight,
            kCVPixelBufferPixelFormatTypeKey: configuration.pixelFormat,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess else { return nil }
        return pool
    }

    private func makeVirtualCameraPixelBuffer(from imageBuffer: CVImageBuffer) -> CVPixelBuffer? {
        guard
            let commandQueue,
            let pipelineState,
            let textureCache,
            let pixelBufferPool
        else {
            return nil
        }

        let streamWidth = configuration.streamWidth
        let streamHeight = configuration.streamHeight

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        // Create textures
        guard
            let sourceTexture = makeBGRA8Texture(from: imageBuffer, cache: textureCache),
            let outputTexture = makeBGRA8Texture(from: pixelBuffer, cache: textureCache)
        else {
            return nil
        }

        // Calculate scale and offset for aspect-fit centering
        let sourceWidth = Float(CVPixelBufferGetWidth(imageBuffer))
        let sourceHeight = Float(CVPixelBufferGetHeight(imageBuffer))
        let targetWidth = Float(streamWidth)
        let targetHeight = Float(streamHeight)

        let scale = min(targetWidth / sourceWidth, targetHeight / sourceHeight)
        let scaledWidth = sourceWidth * scale
        let scaledHeight = sourceHeight * scale
        let offsetX = (targetWidth - scaledWidth) / 2.0
        let offsetY = (targetHeight - scaledHeight) / 2.0

        var params = ScaleParams(
            scale: SIMD2<Float>(scale, scale),
            offset: SIMD2<Float>(offsetX, offsetY)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(outputTexture, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<ScaleParams>.size, index: 0)

        let width = pipelineState.threadExecutionWidth
        let height = max(1, pipelineState.maxTotalThreadsPerThreadgroup / width)
        let threadsPerThreadgroup = MTLSize(width: width, height: height, depth: 1)
        let threadsPerGrid = MTLSize(width: streamWidth, height: streamHeight, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return pixelBuffer
    }

    private func makeBGRA8Texture(from pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) -> MTLTexture? {
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else {
            return nil
        }
        return CVMetalTextureGetTexture(cvTexture)
    }

    func makeSampleBuffer(from sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let pixelBuffer = makeVirtualCameraPixelBuffer(from: imageBuffer) else {
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
