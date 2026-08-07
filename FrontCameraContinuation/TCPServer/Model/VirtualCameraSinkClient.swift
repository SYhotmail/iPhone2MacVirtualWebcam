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
    private var readyToEnqueue = true

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
            connectIfNeeded()
        }
    }

    func stop() {
        logger.debug("Stopping virtual camera sink client")
        if let deviceID, let sinkStreamID {
            CMIODeviceStopStream(deviceID, sinkStreamID)
            logger.debug("Stopped sink stream \(sinkStreamID)")
        }

        deviceID = nil
        sinkStreamID = nil
        sinkQueue = nil
        readyToEnqueue = true
    }

    
    func enqueue(_ sampleBuffer: H264Decoder.SendableSampleBuffer) {
        connectIfNeeded()
        guard readyToEnqueue else { return }
        guard let sinkQueue else { return }
        guard CMSimpleQueueGetCount(sinkQueue) < CMSimpleQueueGetCapacity(sinkQueue) else { return }

        readyToEnqueue = false
        
        let imageBuffer = sampleBuffer.value.imageBuffer
        
        let sampleBuffer = imageBuffer.flatMap { H264Decoder.makeSampleBuffer(from: $0) }
        let retainedSampleBuffer = Unmanaged.passRetained(sampleBuffer!) // TODO: fix me...
        let status = CMSimpleQueueEnqueue(sinkQueue, element: retainedSampleBuffer.toOpaque())
        let success = status == noErr
        readyToEnqueue = !success
        guard success else {
            readyToEnqueue = true
            retainedSampleBuffer.release()
            logger.debug("Failed to enqueue sample buffer, status=\(status)")
            return
        }
        
        logger.debug("Enqueued sample buffer to sink stream \(self.sinkStreamID ?? 0)")
    }

    @discardableResult
    private func ensureVideoAccessAndConnect(mediaType: AVMediaType) -> AVAuthorizationStatus {
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        switch status {
        case .authorized:
            connectIfNeeded()
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

    private func connectIfNeeded() {
        guard sinkQueue == nil else { return }
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

        let refCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = CMIOStreamCopyBufferQueue(
            sinkStreamID,
            { _, token, refCon in
                guard let refCon else { return }
                let sinkClient = Unmanaged<VirtualCameraSinkClient>.fromOpaque(refCon).takeUnretainedValue()
                Task { [sinkClient] in
                    await sinkClient.markReadyToEnqueue()
                }
                
                /*if let token { // TODO: fix me.
                    Unmanaged<CMSampleBuffer>.fromOpaque(token).release()
                }*/
            },
            refCon,
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
        self.readyToEnqueue = true
        logger.debug("Connected sink client to device \(cmioDeviceID), sink stream \(sinkStreamID), name=\(device.localizedName, privacy: .public)")
    }

    private func markReadyToEnqueue() {
        readyToEnqueue = true
        logger.debug("Sink stream is ready for another sample buffer")
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
