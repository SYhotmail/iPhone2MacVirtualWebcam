import Foundation
import CoreImage
import CoreMedia
import CoreVideo

struct SharedFrame {
    let pixelBuffer: CVPixelBuffer
    let hostTimeInNanoseconds: UInt64
    let sequenceNumber: UInt64
}

private struct SharedFrameHeader {
    static let magic = UInt32(0x5643414D) // VCAM
    static let version = UInt32(1)
    static let encodedSize = MemoryLayout<UInt32>.size * 6 + MemoryLayout<UInt64>.size * 2

    var width: UInt32
    var height: UInt32
    var bytesPerRow: UInt32
    var pixelFormat: UInt32
    var sequenceNumber: UInt64
    var hostTimeInNanoseconds: UInt64

    func encoded() -> Data {
        var data = Data(capacity: Self.encodedSize)
        [Self.magic, Self.version, width, height, bytesPerRow, pixelFormat].forEach {
            var value = $0
            data.append(Data(bytes: &value, count: MemoryLayout.size(ofValue: value)))
        }
        [sequenceNumber, hostTimeInNanoseconds].forEach {
            var value = $0
            data.append(Data(bytes: &value, count: MemoryLayout.size(ofValue: value)))
        }
        return data
    }

    static func decode(from data: Data) -> SharedFrameHeader? {
        guard data.count >= encodedSize else { return nil }

        var offset = 0
        func readUInt32() -> UInt32 {
            defer { offset += MemoryLayout<UInt32>.size }
            return data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
        }

        func readUInt64() -> UInt64 {
            defer { offset += MemoryLayout<UInt64>.size }
            return data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt64.self) }
        }

        let magic = readUInt32()
        let version = readUInt32()
        guard magic == Self.magic, version == Self.version else { return nil }

        return SharedFrameHeader(
            width: readUInt32(),
            height: readUInt32(),
            bytesPerRow: readUInt32(),
            pixelFormat: readUInt32(),
            sequenceNumber: readUInt64(),
            hostTimeInNanoseconds: readUInt64()
        )
    }
}

final class SharedFrameWriter {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let fileManager = FileManager.default
    private var sequenceNumber: UInt64 = 0

    func publish(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let outputURL = sharedFrameURL(),
              let scaledBuffer = makeScaledPixelBuffer(from: imageBuffer) else {
            return
        }

        CVPixelBufferLockBaseAddress(scaledBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(scaledBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(scaledBuffer) else { return }

        sequenceNumber += 1

        let bytesPerRow = CVPixelBufferGetBytesPerRow(scaledBuffer)
        let payloadSize = bytesPerRow * CVPixelBufferGetHeight(scaledBuffer)
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        let hostTimeInNanoseconds = UInt64((hostTime.seconds * 1_000_000_000).rounded())

        let header = SharedFrameHeader(
            width: UInt32(CVPixelBufferGetWidth(scaledBuffer)),
            height: UInt32(CVPixelBufferGetHeight(scaledBuffer)),
            bytesPerRow: UInt32(bytesPerRow),
            pixelFormat: CVPixelBufferGetPixelFormatType(scaledBuffer),
            sequenceNumber: sequenceNumber,
            hostTimeInNanoseconds: hostTimeInNanoseconds
        )

        var data = header.encoded()
        data.append(baseAddress.assumingMemoryBound(to: UInt8.self), count: payloadSize)

        do {
            try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: outputURL, options: .atomic)
        } catch {
            debugPrint("Failed to publish shared frame: \(error.localizedDescription)")
        }
    }

    func clear() {
        guard let outputURL = sharedFrameURL() else { return }
        try? fileManager.removeItem(at: outputURL)
    }

    private func makeScaledPixelBuffer(from imageBuffer: CVImageBuffer) -> CVPixelBuffer? {
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
        let scaleX = targetRect.width / image.extent.width
        let scaleY = targetRect.height / image.extent.height
        let scaledImage = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        context.render(scaledImage, to: pixelBuffer, bounds: targetRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        return pixelBuffer
    }

    private func sharedFrameURL() -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: VirtualCameraConfiguration.appGroupIdentifier)?
            .appendingPathComponent(VirtualCameraConfiguration.frameFileName)
    }
}

final class SharedFrameReader {
    private let fileManager = FileManager.default

    func readFrame() -> SharedFrame? {
        guard let fileURL = sharedFrameURL(),
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              let header = SharedFrameHeader.decode(from: data) else {
            return nil
        }

        let expectedPayloadSize = Int(header.bytesPerRow) * Int(header.height)
        let payloadOffset = SharedFrameHeader.encodedSize
        guard data.count >= payloadOffset + expectedPayloadSize else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: Int(header.width),
            kCVPixelBufferHeightKey: Int(header.height),
            kCVPixelBufferPixelFormatTypeKey: header.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(header.width),
            Int(header.height),
            OSType(header.pixelFormat),
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let destination = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress?.advanced(by: payloadOffset) else { return }
            memcpy(destination, source, expectedPayloadSize)
        }

        return SharedFrame(
            pixelBuffer: pixelBuffer,
            hostTimeInNanoseconds: header.hostTimeInNanoseconds,
            sequenceNumber: header.sequenceNumber
        )
    }

    private func sharedFrameURL() -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: VirtualCameraConfiguration.appGroupIdentifier)?
            .appendingPathComponent(VirtualCameraConfiguration.frameFileName)
    }
}
