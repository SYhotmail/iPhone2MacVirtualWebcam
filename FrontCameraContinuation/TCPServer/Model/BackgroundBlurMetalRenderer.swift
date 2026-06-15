@preconcurrency import AVFoundation
import CoreImage
import Metal
import MetalPerformanceShaders
import Vision

nonisolated
final class BackgroundBlurMetalRenderer {
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let library: MTLLibrary?
    private let pipelineState: MTLComputePipelineState?
    private let textureCache: CVMetalTextureCache?
    private let ciContext: CIContext
    private let segmentationRequest: VNGeneratePersonSegmentationRequest
    private let segmentationHandler = VNSequenceRequestHandler()
    private let lock = NSLock()

    private var colorPool: CVPixelBufferPool?
    private var maskPool: CVPixelBufferPool?
    private var colorConfiguration: PoolConfiguration?
    private var maskConfiguration: PoolConfiguration?

    init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        self.library = try? device?.makeDefaultLibrary(bundle: .main)
        if let device,
           let library,
           let function = library.makeFunction(name: "compositePersonMask") {
            self.pipelineState = try? device.makeComputePipelineState(function: function)
        } else {
            self.pipelineState = nil
        }

        var textureCache: CVMetalTextureCache?
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
        self.textureCache = textureCache

        if let device {
            self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            self.ciContext = CIContext(options: [.cacheIntermediates: false])
        }

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        self.segmentationRequest = request
    }

    func process(_ sampleBuffer: CMSampleBuffer, effect: VideoEffect) -> CMSampleBuffer? {
        guard effect != .none else {
            return sampleBuffer
        }

        lock.lock()
        defer {
            lock.unlock()
        }

        guard
            let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            let maskBuffer = makeMaskBuffer(for: imageBuffer),
            let sourceBuffer = makeColorBuffer(matching: imageBuffer),
            let blurredBuffer = makeColorBuffer(matching: imageBuffer),
            let outputBuffer = makeColorBuffer(matching: imageBuffer),
            let sourceImage = makeSourceImage(from: imageBuffer)
        else {
            return nil
        }

        let extent = sourceImage.extent
        ciContext.render(sourceImage, to: sourceBuffer, bounds: extent, colorSpace: CGColorSpaceCreateDeviceRGB())

        guard
            let sourceTexture = makeBGRA8Texture(from: sourceBuffer),
            let blurredTexture = makeBGRA8Texture(from: blurredBuffer),
            let outputTexture = makeBGRA8Texture(from: outputBuffer),
            let maskTexture = makeR8Texture(from: maskBuffer),
            let commandQueue,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return nil
        }

        guard let device else {
            return nil
        }

        let blurFilter = MPSImageGaussianBlur(device: device, sigma: effect.blurSigma)
        blurFilter.encode(commandBuffer: commandBuffer, sourceTexture: sourceTexture, destinationTexture: blurredTexture)

        guard let pipelineState else {
            return nil
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(blurredTexture, index: 1)
        encoder.setTexture(maskTexture, index: 2)
        encoder.setTexture(outputTexture, index: 3)

        let width = pipelineState.threadExecutionWidth
        let height = max(1, pipelineState.maxTotalThreadsPerThreadgroup / width)
        let threadsPerThreadgroup = MTLSize(width: width, height: height, depth: 1)
        let threadsPerGrid = MTLSize(width: outputTexture.width, height: outputTexture.height, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return makeSampleBuffer(from: outputBuffer, source: sampleBuffer)
    }

    private func makeSourceImage(from imageBuffer: CVPixelBuffer) -> CIImage? {
        let image = CIImage(cvPixelBuffer: imageBuffer)
        return image.extent.isEmpty ? nil : image
    }

    private func makeMaskBuffer(for imageBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        try? segmentationHandler.perform([segmentationRequest], on: imageBuffer)
        guard let observation = segmentationRequest.results?.first else {
            return nil
        }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        guard let maskBuffer = makeMaskBuffer(width: width, height: height) else {
            return nil
        }

        let maskImage = CIImage(cvPixelBuffer: observation.pixelBuffer)
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(width) / CGFloat(CVPixelBufferGetWidth(observation.pixelBuffer)),
                y: CGFloat(height) / CGFloat(CVPixelBufferGetHeight(observation.pixelBuffer))
            ))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 4])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

        ciContext.render(maskImage, to: maskBuffer, bounds: maskImage.extent, colorSpace: nil)
        return maskBuffer
    }

    private func makeColorBuffer(matching imageBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let configuration = PoolConfiguration(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer),
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        if configuration != colorConfiguration {
            colorPool = makePixelBufferPool(configuration: configuration)
            colorConfiguration = configuration
        }

        guard let colorPool else {
            return nil
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, colorPool, &pixelBuffer)
        guard status == kCVReturnSuccess else {
            return nil
        }
        return pixelBuffer
    }

    private func makeMaskBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let configuration = PoolConfiguration(width: width, height: height, pixelFormat: kCVPixelFormatType_OneComponent8)

        if configuration != maskConfiguration {
            maskPool = makePixelBufferPool(configuration: configuration)
            maskConfiguration = configuration
        }

        guard let maskPool else {
            return nil
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, maskPool, &pixelBuffer)
        guard status == kCVReturnSuccess else {
            return nil
        }
        return pixelBuffer
    }

    private func makePixelBufferPool(configuration: PoolConfiguration) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: configuration.pixelFormat,
            kCVPixelBufferWidthKey as String: configuration.width,
            kCVPixelBufferHeightKey as String: configuration.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess else {
            return nil
        }
        return pool
    }

    private func makeBGRA8Texture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache else {
            return nil
        }

        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
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

    private func makeR8Texture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache else {
            return nil
        }

        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r8Unorm,
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

    private func makeSampleBuffer(from imageBuffer: CVPixelBuffer, source sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        let descriptionStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard descriptionStatus == noErr, let formatDescription else {
            return nil
        }

        var timing = CMSampleTimingInfo()
        let timingStatus = CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing)
        guard timingStatus == noErr else {
            return nil
        }

        var processedSampleBuffer: CMSampleBuffer?
        let sampleBufferStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &processedSampleBuffer
        )
        guard sampleBufferStatus == noErr else {
            return nil
        }

        return processedSampleBuffer
    }
}

extension BackgroundBlurMetalRenderer {
    private struct PoolConfiguration: Equatable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
    }
}
