import Foundation
import CoreMedia
@preconcurrency import CoreMediaIO
import IOKit.audio
import OSLog
import Synchronization

// MARK: -

final class VirtualCameraExtensionDeviceSource: NSObject, @unchecked Sendable, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private let logger = Logger(subsystem: "by.sy.TCPServer.Cam2Mac", category: "sink-forwarder")

    fileprivate var streamSource: VirtualCameraExtensionSourceStream!
    fileprivate var streamSink: VirtualCameraExtensionSinkStream!

    private var streamingCounter: UInt32 = 0
    private var streamingSinkCounter: UInt32 = 0
    private var sinkStarted = false
    /// Incremented on every sink start/stop so that only one consume loop is alive.
    private var sinkGeneration: UInt64 = 0
    private let consumeQueue = DispatchQueue(label: "by.sy.TCPServer.Cam2Mac.sink-consume")
    
    private let lock = Mutex(())
    
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

    private func startStreamingCore() {
        streamingCounter += 1
        logger.error("Source stream started. count=\(self.streamingCounter)")
    }
    
    func startStreaming() {
        lock.withLock { _ in
            startStreamingCore()
        }
    }

    private func stopStreamingCore() {
        if streamingCounter > 1 {
            streamingCounter -= 1
        } else {
            streamingCounter = 0
        }
        logger.error("Source stream stopped. count=\(self.streamingCounter)")
    }
    
    func stopStreaming() {
        lock.withLock { _ in
            stopStreamingCore()
        }
    }

    private func startStreamingSinkCore() {
        streamingSinkCounter += 1
        sinkStarted = true
        sinkGeneration &+= 1
        logger.error("Sink stream started. count=\(self.streamingSinkCounter)")
    }
    
    func startStreamingSink(client: CMIOExtensionClient) {
        let generation = lock.withLock { _ in
            startStreamingSinkCore()
            return sinkGeneration
        }

        consumeBuffers(from: client, generation: generation)
    }
    

    private func stopStreamingSinkCore() {
        sinkStarted = false
        sinkGeneration &+= 1
        if streamingSinkCounter > 1 {
            streamingSinkCounter -= 1
        } else {
            streamingSinkCounter = 0
        }
        logger.error("Sink stream stopped. count=\(self.streamingSinkCounter)")
    }
    
    func stopStreamingSink() {
        lock.withLock { _ in
            stopStreamingSinkCore()
        }
    }
    
    var hasStreamingCounter: Bool {
        lock.withLock { _ in
            streamingCounter > 0
        }
    }
    
    private func isSinkActive(generation: UInt64) -> Bool {
        lock.withLock { _ in
            sinkStarted && sinkGeneration == generation
        }
    }
    
    private func forwardToSource(_ sampleBuffer: CMSampleBuffer, sequenceNumber: UInt64) {
        let hostTimeInNanoseconds = UInt64(sampleBuffer.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
        let scheduledOutput = CMIOExtensionScheduledOutput(
            sequenceNumber: sequenceNumber,
            hostTimeInNanoseconds: hostTimeInNanoseconds
        )

        guard let stream = streamSource.stream else { return }
        if hasStreamingCounter {
            stream.send(
                sampleBuffer,
                discontinuity: [],
                hostTimeInNanoseconds: hostTimeInNanoseconds
            )
        }

        streamSink.stream.notifyScheduledOutputChanged(scheduledOutput)
    }

    private func consumeBuffers(from client: CMIOExtensionClient, generation: UInt64) {
        guard isSinkActive(generation: generation) else { return }

        streamSink.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, _, error in
            guard let self else { return }
            guard self.isSinkActive(generation: generation) else { return }

            if let sampleBuffer {
                self.forwardToSource(sampleBuffer, sequenceNumber: sequenceNumber)
                self.consumeQueue.async {
                    self.consumeBuffers(from: client, generation: generation)
                }
            } else {
                // No buffer queued yet (or a transient error): back off instead of
                // spinning, then try again.
                if let error {
                    self.logger.debug("Sink consume failed: \(error.localizedDescription, privacy: .public)")
                }
                let delay = VirtualCameraConfiguration.frameDuration.seconds / 2
                self.consumeQueue.asyncAfter(deadline: .now() + delay) {
                    self.consumeBuffers(from: client, generation: generation)
                }
            }
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
