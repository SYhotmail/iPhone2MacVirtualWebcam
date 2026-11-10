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

    /// Small jitter buffer between the sink (bursty network arrival) and the source
    /// (steady frame cadence). Frames that arrive back-to-back are spread over
    /// consecutive ticks instead of being shown at once / overwritten.
    private var pendingFrames: [CMSampleBuffer] = []
    private static let maxPendingFrames = 3
    private var outputTimer: DispatchSourceTimer?
    /// Consecutive ticks with more than one spare frame queued (sustained backlog).
    private var backlogTicks = 0
    
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
        let generation = lock.withLock { _ -> UInt64 in
            startStreamingSinkCore()
            return sinkGeneration
        }

        startOutputTimer()
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
        let shouldStopTimer = lock.withLock { _ -> Bool in
            stopStreamingSinkCore()
            if streamingSinkCounter == 0 {
                pendingFrames.removeAll()
                backlogTicks = 0
                return true
            }
            return false
        }
        if shouldStopTimer {
            stopOutputTimer()
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
    
    private func enqueuePendingFrame(_ sampleBuffer: CMSampleBuffer, sequenceNumber: UInt64) {
        lock.withLock { _ in
            pendingFrames.append(sampleBuffer)
            if pendingFrames.count > Self.maxPendingFrames {
                pendingFrames.removeFirst(pendingFrames.count - Self.maxPendingFrames)
            }
        }

        let hostTimeInNanoseconds = UInt64(sampleBuffer.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
        streamSink.stream.notifyScheduledOutputChanged(
            CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber,
                                         hostTimeInNanoseconds: hostTimeInNanoseconds)
        )
    }

    private struct PendingFrame: @unchecked Sendable {
        let sampleBuffer: CMSampleBuffer
    }

    private func dequeuePendingFrame() -> CMSampleBuffer? {
        let frame = lock.withLock { _ -> PendingFrame? in
            guard streamingCounter > 0, !pendingFrames.isEmpty else { return nil }
            // Short bursts are absorbed and played out one per tick. Only when a
            // backlog persists for ~1s (sender clock slightly faster than ours) skip a
            // frame, so latency doesn't keep growing.
            if pendingFrames.count > 1 {
                backlogTicks += 1
                if backlogTicks >= VirtualCameraConfiguration.frameRate {
                    pendingFrames.removeFirst()
                    backlogTicks = 0
                }
            } else {
                backlogTicks = 0
            }
            return PendingFrame(sampleBuffer: pendingFrames.removeFirst())
        }
        return frame?.sampleBuffer
    }

    private func startOutputTimer() {
        consumeQueue.async { [weak self] in
            guard let self, self.outputTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self.consumeQueue)
            let interval = VirtualCameraConfiguration.frameDuration.seconds
            timer.schedule(deadline: .now() + interval,
                           repeating: interval,
                           leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                self?.emitNextFrame()
            }
            self.outputTimer = timer
            timer.resume()
        }
    }

    private func stopOutputTimer() {
        consumeQueue.async { [weak self] in
            self?.outputTimer?.cancel()
            self?.outputTimer = nil
        }
    }

    /// Called on `consumeQueue` once per frame duration.
    private func emitNextFrame() {
        guard let sampleBuffer = dequeuePendingFrame(),
              let stream = streamSource.stream else {
            return
        }

        // Re-stamp with the actual output time so consumers see an evenly spaced,
        // monotonic timeline.
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: VirtualCameraConfiguration.frameDuration,
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        let output = (status == noErr ? retimed : nil) ?? sampleBuffer

        stream.send(
            output,
            discontinuity: [],
            hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC))
        )
    }

    private func consumeBuffers(from client: CMIOExtensionClient, generation: UInt64) {
        guard isSinkActive(generation: generation) else { return }

        streamSink.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, _, error in
            guard let self else { return }
            guard self.isSinkActive(generation: generation) else { return }

            if let sampleBuffer {
                self.enqueuePendingFrame(sampleBuffer, sequenceNumber: sequenceNumber)
                self.consumeQueue.async {
                    self.consumeBuffers(from: client, generation: generation)
                }
            } else {
                // No buffer queued yet (or a transient error): back off instead of
                // spinning, then try again.
                if let error {
                    self.logger.debug("Sink consume failed: \(error.localizedDescription, privacy: .public)")
                }
                // Poll often enough that a queued frame waits only a few ms.
                let delay = 0.004
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
            // Room for a burst of frames from the network so none are dropped
            // before the extension reads them.
            streamProperties.sinkBufferQueueSize = 4
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
