import Foundation
import CoreMedia
import CoreMediaIO
import IOKit.audio
import OSLog

// MARK: -

final class VirtualCameraExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private let logger = Logger(subsystem: "by.sy.TCPServer.VirtualCameraExtension", category: "sink-forwarder")

    fileprivate var streamSource: VirtualCameraExtensionSourceStream!
    fileprivate var streamSink: VirtualCameraExtensionSinkStream!

    private var streamingCounter: UInt32 = 0
    private var streamingSinkCounter: UInt32 = 0
    private var sinkStarted = false

    init(localizedName: String) {
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: VirtualCameraConfiguration.pixelFormat,
            width: Int32(VirtualCameraConfiguration.streamWidth),
            height: Int32(VirtualCameraConfiguration.streamHeight),
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        let videoDescription = formatDescription!

        super.init()

        let deviceID = UUID()
        self.device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: deviceID,
            legacyDeviceID: nil,
            source: self
        )

        let videoStreamFormat = CMIOExtensionStreamFormat(
            formatDescription: videoDescription,
            maxFrameDuration: VirtualCameraConfiguration.frameDuration,
            minFrameDuration: VirtualCameraConfiguration.frameDuration,
            validFrameDurations: nil
        )

        streamSource = VirtualCameraExtensionSourceStream(
            localizedName: "\(localizedName).Video",
            streamID: UUID(),
            streamFormat: videoStreamFormat,
            device: device
        )
        streamSink = VirtualCameraExtensionSinkStream(
            localizedName: "\(localizedName).Video.Sink",
            streamID: UUID(),
            streamFormat: videoStreamFormat,
            device: device
        )

        do {
            try device.addStream(streamSource.stream)
            try device.addStream(streamSink.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = VirtualCameraConfiguration.modelName
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func startStreaming() {
        streamingCounter += 1
        logger.error("Source stream started. count=\(self.streamingCounter)")
    }

    func stopStreaming() {
        if streamingCounter > 1 {
            streamingCounter -= 1
        } else {
            streamingCounter = 0
        }
        logger.error("Source stream stopped. count=\(self.streamingCounter)")
    }

    func startStreamingSink(client: CMIOExtensionClient) {
        streamingSinkCounter += 1
        sinkStarted = true
        logger.error("Sink stream started. count=\(self.streamingSinkCounter)")
        consumeBuffers(from: client)
    }

    func stopStreamingSink() {
        sinkStarted = false
        if streamingSinkCounter > 1 {
            streamingSinkCounter -= 1
        } else {
            streamingSinkCounter = 0
        }
        logger.error("Sink stream stopped. count=\(self.streamingSinkCounter)")
    }

    private func consumeBuffers(from client: CMIOExtensionClient) {
        guard sinkStarted else { return }

        streamSink.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, _, _ in
            guard let self else { return }
            defer { self.consumeBuffers(from: client) }
            guard let sampleBuffer else {
                self.logger.error("Sink consume returned nil sample buffer")
                return
            }

            let hostTimeInNanoseconds = UInt64(sampleBuffer.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
            self.logger.error("Consumed sink sample buffer seq=\(sequenceNumber) host=\(hostTimeInNanoseconds)")
            let scheduledOutput = CMIOExtensionScheduledOutput(
                sequenceNumber: sequenceNumber,
                hostTimeInNanoseconds: hostTimeInNanoseconds
            )

            if self.streamingCounter > 0 {
                self.streamSource.stream.send(
                    sampleBuffer,
                    discontinuity: [],
                    hostTimeInNanoseconds: hostTimeInNanoseconds
                )
                self.logger.error("Forwarded sink sample buffer to source seq=\(sequenceNumber)")
            } else {
                self.logger.error("Dropped sink sample buffer because source stream is inactive")
            }

            self.streamSink.stream.notifyScheduledOutputChanged(scheduledOutput)
        }
    }
}

// MARK: -

final class VirtualCameraExtensionSourceStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!

    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] {
        [streamFormat]
    }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = VirtualCameraConfiguration.frameDuration
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = formats.indices.contains(activeFormatIndex) ? activeFormatIndex : 0
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? VirtualCameraExtensionDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? VirtualCameraExtensionDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.stopStreaming()
    }
}

final class VirtualCameraExtensionSinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!

    let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .sink,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] {
        [streamFormat]
    }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [
            .streamActiveFormatIndex,
            .streamFrameDuration,
            .streamSinkBufferQueueSize,
            .streamSinkBuffersRequiredForStartup,
            .streamSinkBufferUnderrunCount,
            .streamSinkEndOfData
        ]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = VirtualCameraConfiguration.frameDuration
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 1
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = formats.indices.contains(activeFormatIndex) ? activeFormatIndex : 0
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? VirtualCameraExtensionDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        guard let client else { return }
        deviceSource.startStreamingSink(client: client)
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? VirtualCameraExtensionDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.stopStreamingSink()
    }
}

// MARK: -

final class VirtualCameraExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!

    private var deviceSource: VirtualCameraExtensionDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()

        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = VirtualCameraExtensionDeviceSource(localizedName: VirtualCameraConfiguration.deviceName)

        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = VirtualCameraConfiguration.manufacturerName
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
