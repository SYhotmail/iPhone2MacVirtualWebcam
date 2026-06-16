@preconcurrency import AVFoundation
import AppKit
import Metal
import MetalPerformanceShaders
import Vision

nonisolated
final class BackgroundBlurMetalRenderer {
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let yuvToBGRAPipeline: MTLComputePipelineState?
    private let compositePipeline: MTLComputePipelineState?
    private let compositeBackgroundPipeline: MTLComputePipelineState?
    private let textureCache: CVMetalTextureCache?
    private let segmentationRequest: VNGeneratePersonSegmentationRequest
    private let segmentationHandler = VNSequenceRequestHandler()
    private let lock = NSLock()

    private var colorPool: CVPixelBufferPool?
    private var maskPool: CVPixelBufferPool?
    private var colorConfiguration: PoolConfiguration?
    private var maskConfiguration: PoolConfiguration?

    private var backgroundTexture: MTLTexture?

    init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()

        let library = try? device?.makeDefaultLibrary(bundle: .main)

        if let device, let library {
            if let yuvFunction = library.makeFunction(name: "yuvToBGRA") {
                self.yuvToBGRAPipeline = try? device.makeComputePipelineState(function: yuvFunction)
            } else {
                self.yuvToBGRAPipeline = nil
            }

            if let compositeFunction = library.makeFunction(name: "compositePersonMask") {
                self.compositePipeline = try? device.makeComputePipelineState(function: compositeFunction)
            } else {
                self.compositePipeline = nil
            }

            if let compositeBackgroundFunction = library.makeFunction(name: "compositePersonOverBackground") {
                self.compositeBackgroundPipeline = try? device.makeComputePipelineState(function: compositeBackgroundFunction)
            } else {
                self.compositeBackgroundPipeline = nil
            }
        } else {
            self.yuvToBGRAPipeline = nil
            self.compositePipeline = nil
            self.compositeBackgroundPipeline = nil
        }

        var textureCache: CVMetalTextureCache?
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
        self.textureCache = textureCache

        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        self.segmentationRequest = request
    }

    func setBackgroundImage(_ image: NSImage?) {
        lock.lock()
        defer { lock.unlock() }

        guard let device, let image else {
            backgroundTexture = nil
            return
        }

        backgroundTexture = createTexture(from: image, device: device)
    }

    private func createTexture(from image: NSImage, device: MTLDevice) -> MTLTexture? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else {
            return nil
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )

        return texture
    }

    func process(_ sampleBuffer: CMSampleBuffer, effect: VideoEffect) -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard
            let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            let device,
            let commandQueue,
            let yuvToBGRAPipeline
        else {
            return nil
        }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        // Create source buffer for BGRA conversion
        guard let sourceBuffer = makeColorBuffer(width: width, height: height) else {
            return nil
        }

        guard let sourceTexture = makeBGRA8Texture(from: sourceBuffer) else {
            return nil
        }

        // Step 1: Convert YUV to BGRA (or copy if already BGRA)
        guard let convertBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            // YUV input - convert to BGRA
            guard
                let yTexture = makeYTexture(from: imageBuffer),
                let uvTexture = makeUVTexture(from: imageBuffer)
            else {
                return nil
            }

            guard let encoder = convertBuffer.makeComputeCommandEncoder() else {
                return nil
            }
            encoder.setComputePipelineState(yuvToBGRAPipeline)
            encoder.setTexture(yTexture, index: 0)
            encoder.setTexture(uvTexture, index: 1)
            encoder.setTexture(sourceTexture, index: 2)
            dispatchThreads(encoder: encoder, pipeline: yuvToBGRAPipeline, texture: sourceTexture)
            encoder.endEncoding()
        } else {
            // Assume BGRA - copy directly
            guard let inputTexture = makeBGRA8Texture(from: imageBuffer) else {
                return nil
            }
            let blitEncoder = convertBuffer.makeBlitCommandEncoder()
            blitEncoder?.copy(from: inputTexture, to: sourceTexture)
            blitEncoder?.endEncoding()
        }

        convertBuffer.commit()
        convertBuffer.waitUntilCompleted()

        // If no effect, just return the converted BGRA buffer
        if effect.isNone {
            return makeSampleBuffer(from: sourceBuffer, source: sampleBuffer)
        }

        // Handle background image effect
        if effect.isBackgroundImage {
            return processBackgroundImage(
                sourceBuffer: sourceBuffer,
                sourceTexture: sourceTexture,
                imageBuffer: imageBuffer,
                sampleBuffer: sampleBuffer,
                device: device,
                commandQueue: commandQueue,
                width: width,
                height: height
            )
        }

        // Handle blur effect
        return processBlur(
            sourceBuffer: sourceBuffer,
            sourceTexture: sourceTexture,
            imageBuffer: imageBuffer,
            sampleBuffer: sampleBuffer,
            effect: effect,
            device: device,
            commandQueue: commandQueue,
            width: width,
            height: height
        )
    }

    private func processBlur(
        sourceBuffer: CVPixelBuffer,
        sourceTexture: MTLTexture,
        imageBuffer: CVPixelBuffer,
        sampleBuffer: CMSampleBuffer,
        effect: VideoEffect,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        width: Int,
        height: Int
    ) -> CMSampleBuffer? {
        guard let compositePipeline else {
            return nil
        }

        // Create additional buffers for blur effect
        guard
            let blurredBuffer = makeColorBuffer(width: width, height: height),
            let outputBuffer = makeColorBuffer(width: width, height: height),
            let scaledMaskBuffer = makeScaledMaskBuffer(width: width, height: height)
        else {
            return nil
        }

        guard
            let blurredTexture = makeBGRA8Texture(from: blurredBuffer),
            let outputTexture = makeBGRA8Texture(from: outputBuffer),
            let scaledMaskTexture = makeR8Texture(from: scaledMaskBuffer)
        else {
            return nil
        }

        // Apply Gaussian blur to source for background
        guard let blurCommandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        let blurFilter = MPSImageGaussianBlur(device: device, sigma: effect.blurSigma)
        blurFilter.encode(commandBuffer: blurCommandBuffer, sourceTexture: sourceTexture, destinationTexture: blurredTexture)

        blurCommandBuffer.commit()
        blurCommandBuffer.waitUntilCompleted()

        // Get person segmentation mask and scale it
        guard processMask(for: imageBuffer, to: scaledMaskBuffer, device: device) else {
            return nil
        }

        // Composite person over blurred background
        guard let compositeCommandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        guard let encoder = compositeCommandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(blurredTexture, index: 1)
        encoder.setTexture(scaledMaskTexture, index: 2)
        encoder.setTexture(outputTexture, index: 3)
        dispatchThreads(encoder: encoder, pipeline: compositePipeline, texture: outputTexture)
        encoder.endEncoding()

        compositeCommandBuffer.commit()
        compositeCommandBuffer.waitUntilCompleted()

        return makeSampleBuffer(from: outputBuffer, source: sampleBuffer)
    }

    private func processBackgroundImage(
        sourceBuffer: CVPixelBuffer,
        sourceTexture: MTLTexture,
        imageBuffer: CVPixelBuffer,
        sampleBuffer: CMSampleBuffer,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        width: Int,
        height: Int
    ) -> CMSampleBuffer? {
        guard let compositeBackgroundPipeline, let backgroundTexture else {
            // No background image set, return source
            return makeSampleBuffer(from: sourceBuffer, source: sampleBuffer)
        }

        guard
            let outputBuffer = makeColorBuffer(width: width, height: height),
            let scaledMaskBuffer = makeScaledMaskBuffer(width: width, height: height)
        else {
            return nil
        }

        guard
            let outputTexture = makeBGRA8Texture(from: outputBuffer),
            let scaledMaskTexture = makeR8Texture(from: scaledMaskBuffer)
        else {
            return nil
        }

        // Get person segmentation mask and scale it
        guard processMask(for: imageBuffer, to: scaledMaskBuffer, device: device) else {
            return nil
        }

        // Composite person over background image
        guard let compositeCommandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }

        guard let encoder = compositeCommandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        encoder.setComputePipelineState(compositeBackgroundPipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(backgroundTexture, index: 1)
        encoder.setTexture(scaledMaskTexture, index: 2)
        encoder.setTexture(outputTexture, index: 3)
        dispatchThreads(encoder: encoder, pipeline: compositeBackgroundPipeline, texture: outputTexture)
        encoder.endEncoding()

        compositeCommandBuffer.commit()
        compositeCommandBuffer.waitUntilCompleted()

        return makeSampleBuffer(from: outputBuffer, source: sampleBuffer)
    }

    private func processMask(for imageBuffer: CVPixelBuffer, to scaledMaskBuffer: CVPixelBuffer, device: MTLDevice) -> Bool {
        // Run segmentation
        do {
            try segmentationHandler.perform([segmentationRequest], on: imageBuffer)
        } catch {
            return false
        }

        guard let observation = segmentationRequest.results?.first else {
            return false
        }

        let maskPixelBuffer = observation.pixelBuffer
        let targetWidth = CVPixelBufferGetWidth(scaledMaskBuffer)
        let targetHeight = CVPixelBufferGetHeight(scaledMaskBuffer)

        // Create texture from mask
        guard
            let maskTexture = makeR8Texture(from: maskPixelBuffer),
            let scaledMaskTexture = makeR8Texture(from: scaledMaskBuffer),
            let commandQueue
        else {
            return false
        }

        // Use MPS to scale the mask with bilinear filtering
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        let scaleFilter = MPSImageBilinearScale(device: device)
        scaleFilter.encode(
            commandBuffer: commandBuffer,
            sourceTexture: maskTexture,
            destinationTexture: scaledMaskTexture
        )

        // Apply slight blur to smooth mask edges
        let maskBlur = MPSImageGaussianBlur(device: device, sigma: 4.0)

        // Create temporary texture for blur output
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: targetWidth,
            height: targetHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let tempTexture = device.makeTexture(descriptor: descriptor) else {
            return false
        }

        maskBlur.encode(
            commandBuffer: commandBuffer,
            sourceTexture: scaledMaskTexture,
            destinationTexture: tempTexture
        )

        // Copy back to scaled mask texture
        let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        blitEncoder?.copy(from: tempTexture, to: scaledMaskTexture)
        blitEncoder?.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return true
    }

    private func dispatchThreads(encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, texture: MTLTexture) {
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        let threadsPerThreadgroup = MTLSize(width: width, height: height, depth: 1)
        let threadsPerGrid = MTLSize(width: texture.width, height: texture.height, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    }

    private func makeColorBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let configuration = PoolConfiguration(
            width: width,
            height: height,
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

    private func makeScaledMaskBuffer(width: Int, height: Int) -> CVPixelBuffer? {
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

    private func makeYTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
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
            0,  // Y plane
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else {
            return nil
        }
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func makeUVTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache else {
            return nil
        }

        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(pixelBuffer) / 2
        let height = CVPixelBufferGetHeight(pixelBuffer) / 2
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg8Unorm,
            width,
            height,
            1,  // UV plane
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else {
            return nil
        }
        return CVMetalTextureGetTexture(cvTexture)
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
