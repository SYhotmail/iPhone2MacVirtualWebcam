import AVFoundation
import CoreMedia
import CoreMediaIO
import OSLog
import Synchronization
import H264

actor VirtualCameraSinkClient {
    private let logger = Logger(subsystem: "by.sy.TCPServer", category: "virtual-camera-sink")

    private var deviceID: CMIODeviceID?
    private var sinkStreamID: CMIOStreamID?
    private var sinkQueue: CMSimpleQueue?

    /// When the sink queue became full and stopped draining. Used to detect a dead
    /// consumer (extension restarted/upgraded/crashed) so we can reconnect instead of
    /// stalling forever.
    private var queueFullSince: ContinuousClock.Instant?
    private var lastConnectAttempt: ContinuousClock.Instant?

    private static let stallTimeout: Duration = .seconds(1)
    private static let reconnectInterval: Duration = .seconds(1)

    func start() async {
        logger.debug("Starting virtual camera sink client")
        let mediaType = AVMediaType.video
        let status = ensureVideoAccessAndConnect(mediaType: mediaType)
        if case .notDetermined = status {
            let granted = await AVCaptureDevice.requestAccess(for: mediaType)
            guard granted else {
                logger.debug("Camera access denied")
                return
            }
            logger.debug("Camera access granted")
            connectIfNeeded(force: true)
        }
    }

    func stop() {
        logger.debug("Stopping virtual camera sink client")
        disconnect()
        lastConnectAttempt = nil
    }

    func enqueue(_ sampleBuffer: H264Decoder.SendableSampleBuffer) {
        connectIfNeeded()
        guard let sinkQueue else { return }

        // The CMIO DAL drains this queue when the extension consumes a buffer, so the
        // queue count is the source of truth for back-pressure. Relying solely on the
        // "queue altered" callback can deadlock if a single callback is missed.
        guard CMSimpleQueueGetCount(sinkQueue) < CMSimpleQueueGetCapacity(sinkQueue) else {
            handleFullQueue()
            return
        }
        queueFullSince = nil

        guard let imageBuffer = sampleBuffer.value.imageBuffer,
              let outputSampleBuffer = Self.makeSinkSampleBuffer(from: imageBuffer) else {
            logger.debug("Unable to build sink sample buffer")
            return
        }

        // Ownership of the retained buffer is transferred to the queue; the CMIO DAL
        // releases it after handing it to the extension.
        let retainedSampleBuffer = Unmanaged.passRetained(outputSampleBuffer)
        let status = CMSimpleQueueEnqueue(sinkQueue, element: retainedSampleBuffer.toOpaque())
        guard status == noErr else {
            retainedSampleBuffer.release()
            logger.debug("Failed to enqueue sample buffer, status=\(status)")
            return
        }
    }

    private func handleFullQueue() {
        let now = ContinuousClock.now
        guard let queueFullSince else {
            self.queueFullSince = now
            return
        }
        guard now - queueFullSince > Self.stallTimeout else { return }

        logger.error("Sink queue stopped draining, reconnecting to virtual camera")
        disconnect()
    }

    private func disconnect() {
        if let deviceID, let sinkStreamID {
            CMIODeviceStopStream(deviceID, sinkStreamID)
            logger.debug("Stopped sink stream \(sinkStreamID)")
        }

        if let sinkQueue {
            // Release buffers we still own because nobody dequeued them.
            while let element = CMSimpleQueueDequeue(sinkQueue) {
                Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
            }
        }

        deviceID = nil
        sinkStreamID = nil
        sinkQueue = nil
        queueFullSince = nil
    }

    /// Builds a fresh sample buffer stamped with the current host time so the
    /// extension forwards it with an up-to-date `hostTimeInNanoseconds`.
    private static func makeSinkSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }

        var timingInfo = CMSampleTimingInfo(
            duration: VirtualCameraConfiguration.frameDuration,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }

    @discardableResult
    private func ensureVideoAccessAndConnect(mediaType: AVMediaType) -> AVAuthorizationStatus {
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        switch status {
        case .authorized:
            connectIfNeeded(force: true)
        case .notDetermined:
            logger.debug("Requesting camera access for virtual camera discovery")
        case .denied:
            logger.debug("Camera access denied")
        case .restricted:
            logger.debug("Camera access restricted")
        @unknown default:
            logger.debug("Camera access status unknown")
        }
        return status
    }

    private func connectIfNeeded(force: Bool = false) {
        guard sinkQueue == nil else { return }
        let now = ContinuousClock.now
        if !force, let lastConnectAttempt, now - lastConnectAttempt < Self.reconnectInterval {
            return
        }
        lastConnectAttempt = now
        logger.debug("Attempting sink connection")
        guard let match = findVirtualCamera() else {
            logger.debug("Unable to find a virtual camera device for sink connection")
            return
        }
        let device = match.device
        let cmioDeviceID = match.deviceID
        let sinkStreamID = match.sinkStreamID
        logger.debug("Resolved sink target deviceID=\(cmioDeviceID) streamID=\(sinkStreamID) name=\(device.localizedName, privacy: .public)")

        let queuePointer = UnsafeMutablePointer<Unmanaged<CMSimpleQueue>?>.allocate(capacity: 1)
        queuePointer.initialize(to: nil)
        defer {
            queuePointer.deinitialize(count: 1)
            queuePointer.deallocate()
        }

        let status = CMIOStreamCopyBufferQueue(
            sinkStreamID,
            { _, _, _ in
                // Back-pressure is handled by checking the queue count in `enqueue`.
            },
            nil,
            queuePointer
        )

        logger.debug("CMIOStreamCopyBufferQueue returned status=\(status)")
        guard status == noErr, let unmanagedQueue = queuePointer.pointee else {
            logger.debug("CMIOStreamCopyBufferQueue failed, status=\(status)")
            return
        }

        let queue = unmanagedQueue.takeUnretainedValue()
        let startStatus = CMIODeviceStartStream(cmioDeviceID, sinkStreamID)
        logger.debug("CMIODeviceStartStream returned status=\(startStatus) for sink stream \(sinkStreamID)")
        guard startStatus == noErr else {
            logger.debug("CMIODeviceStartStream failed for sink stream \(sinkStreamID)")
            return
        }

        self.deviceID = cmioDeviceID
        self.sinkStreamID = sinkStreamID
        self.sinkQueue = queue
        self.queueFullSince = nil
        logger.debug("Connected sink client to device \(cmioDeviceID), sink stream \(sinkStreamID), name=\(device.localizedName, privacy: .public)")
    }

    private func findDevice(named name: String) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )

        return discoverySession.devices.first { $0.localizedName == name }
    }

    private func findVirtualCamera() -> (device: AVCaptureDevice, deviceID: CMIODeviceID, sinkStreamID: CMIOStreamID)? {
        if let device = findDevice(named: VirtualCameraConfiguration.deviceName),
           let deviceID = getCMIODeviceID(uid: device.uniqueID),
           let sinkStreamID = getSinkStreamID(deviceID: deviceID) {
            logger.debug("Found virtual camera by configured name \(device.localizedName, privacy: .public)")
            return (device, deviceID, sinkStreamID)
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )

        logger.debug("Scanning \(discoverySession.devices.count) external video device(s) for sink stream")
        for device in discoverySession.devices {
            logger.debug("Inspecting device candidate name=\(device.localizedName, privacy: .public) uid=\(device.uniqueID, privacy: .public)")
            guard let deviceID = getCMIODeviceID(uid: device.uniqueID),
                  let streams = getStreamIDs(deviceID: deviceID),
                  streams.count >= 2,
                  let sinkStreamID = streams.last else {
                logger.debug("Rejected device candidate \(device.localizedName, privacy: .public)")
                continue
            }

            logger.debug("Falling back to virtual camera candidate \(device.localizedName, privacy: .public) with \(streams.count) streams")
            return (device, deviceID, sinkStreamID)
        }

        return nil
    }

    private func getCMIODeviceID(uid: String) -> CMIODeviceID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0

        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            logger.debug("Failed to fetch CMIO device list size")
            return nil
        }

        let deviceCount = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var deviceIDs = [CMIOObjectID](repeating: 0, count: deviceCount)

        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            dataSize,
            &dataUsed,
            &deviceIDs
        ) == noErr else {
            logger.debug("Failed to fetch CMIO device list")
            return nil
        }

        for deviceID in deviceIDs {
            var uidAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var uidDataSize: UInt32 = 0

            guard CMIOObjectGetPropertyDataSize(deviceID, &uidAddress, 0, nil, &uidDataSize) == noErr else {
                continue
            }

            var deviceUID: UnsafeMutableRawPointer?
            
            guard CMIOObjectGetPropertyData(
                deviceID,
                &uidAddress,
                0,
                nil,
                uidDataSize,
                &dataUsed,
                &deviceUID
            ) == noErr, let deviceUID else {
                continue
            }

            let cfUID = Unmanaged<CFString>.fromOpaque(deviceUID).takeUnretainedValue()
            let uidString = cfUID as String
            if uidString == uid {
                logger.debug("Matched AVCapture device uid=\(uid, privacy: .public) to CMIO device \(deviceID)")
                return deviceID
            }
        }

        logger.debug("No CMIO device matched uid=\(uid, privacy: .public)")
        return nil
    }

    private func getSinkStreamID(deviceID: CMIODeviceID) -> CMIOStreamID? {
        getStreamIDs(deviceID: deviceID)?.last
    }

    private func getStreamIDs(deviceID: CMIODeviceID) -> [CMIOStreamID]? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0

        guard CMIOObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            logger.debug("Failed to fetch stream list size for device \(deviceID)")
            return nil
        }

        let streamCount = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streamIDs = [CMIOStreamID](repeating: 0, count: streamCount)

        guard CMIOObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            dataSize,
            &dataUsed,
            &streamIDs
        ) == noErr else {
            logger.debug("Failed to fetch stream list for device \(deviceID)")
            return nil
        }

        logger.debug("Device \(deviceID) exposes \(streamIDs.count) stream(s)")
        return streamIDs
    }
}
