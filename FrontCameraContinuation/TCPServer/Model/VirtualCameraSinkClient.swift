internal import AVFoundation
import CoreMedia
import CoreMediaIO
import OSLog

final class VirtualCameraSinkClient {
    private let lock = NSLock()
    private let logger = Logger(subsystem: "by.sy.TCPServer", category: "virtual-camera-sink")

    private var deviceID: CMIODeviceID?
    private var sinkStreamID: CMIOStreamID?
    private var sinkQueue: CMSimpleQueue?
    private var readyToEnqueue = true

    func start() {
        logger.error("Starting virtual camera sink client")
        ensureVideoAccessAndConnect()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        if let deviceID, let sinkStreamID {
            CMIODeviceStopStream(deviceID, sinkStreamID)
            logger.error("Stopped sink stream \(sinkStreamID)")
        }

        deviceID = nil
        sinkStreamID = nil
        sinkQueue = nil
        readyToEnqueue = true
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }

        connectIfNeeded()

        guard let sinkQueue else { return }
        guard readyToEnqueue else { return }
        guard CMSimpleQueueGetCount(sinkQueue) < CMSimpleQueueGetCapacity(sinkQueue) else { return }

        readyToEnqueue = false
        let retainedSampleBuffer = Unmanaged.passRetained(sampleBuffer)
        let status = CMSimpleQueueEnqueue(sinkQueue, element: retainedSampleBuffer.toOpaque())
        if status != noErr {
            readyToEnqueue = true
            retainedSampleBuffer.release()
            logger.error("Failed to enqueue sample buffer, status=\(status)")
        } else {
            logger.error("Enqueued sample buffer to sink stream \(self.sinkStreamID ?? 0)")
        }
    }

    private func ensureVideoAccessAndConnect() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            lock.lock()
            connectIfNeeded()
            lock.unlock()
        case .notDetermined:
            logger.error("Requesting camera access for virtual camera discovery")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.logger.error("Camera access granted")
                } else {
                    self.logger.error("Camera access denied")
                    return
                }
                self.lock.lock()
                self.connectIfNeeded()
                self.lock.unlock()
            }
        case .denied:
            logger.error("Camera access denied")
        case .restricted:
            logger.error("Camera access restricted")
        @unknown default:
            logger.error("Camera access status unknown")
        }
    }

    private func connectIfNeeded() {
        guard sinkQueue == nil else { return }
        logger.error("Attempting sink connection")
        guard let match = findVirtualCamera() else {
            logger.error("Unable to find a virtual camera device for sink connection")
            return
        }
        let device = match.device
        let cmioDeviceID = match.deviceID
        let sinkStreamID = match.sinkStreamID
        logger.error("Resolved sink target deviceID=\(cmioDeviceID) streamID=\(sinkStreamID) name=\(device.localizedName, privacy: .public)")

        let queuePointer = UnsafeMutablePointer<Unmanaged<CMSimpleQueue>?>.allocate(capacity: 1)
        queuePointer.initialize(to: nil)
        defer {
            queuePointer.deinitialize(count: 1)
            queuePointer.deallocate()
        }

        let refCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = CMIOStreamCopyBufferQueue(
            sinkStreamID,
            { _, _, refCon in
                guard let refCon else { return }
                let sinkClient = Unmanaged<VirtualCameraSinkClient>.fromOpaque(refCon).takeUnretainedValue()
                sinkClient.markReadyToEnqueue()
            },
            refCon,
            queuePointer
        )

        logger.error("CMIOStreamCopyBufferQueue returned status=\(status)")
        guard status == noErr, let unmanagedQueue = queuePointer.pointee else {
            logger.error("CMIOStreamCopyBufferQueue failed, status=\(status)")
            return
        }

        let queue = unmanagedQueue.takeUnretainedValue()
        let startStatus = CMIODeviceStartStream(cmioDeviceID, sinkStreamID)
        logger.error("CMIODeviceStartStream returned status=\(startStatus) for sink stream \(sinkStreamID)")
        guard startStatus == noErr else {
            logger.error("CMIODeviceStartStream failed for sink stream \(sinkStreamID)")
            return
        }

        self.deviceID = cmioDeviceID
        self.sinkStreamID = sinkStreamID
        self.sinkQueue = queue
        self.readyToEnqueue = true
        logger.error("Connected sink client to device \(cmioDeviceID), sink stream \(sinkStreamID), name=\(device.localizedName, privacy: .public)")
    }

    private func markReadyToEnqueue() {
        lock.lock()
        readyToEnqueue = true
        lock.unlock()
        logger.error("Sink stream is ready for another sample buffer")
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
            logger.error("Found virtual camera by configured name \(device.localizedName, privacy: .public)")
            return (device, deviceID, sinkStreamID)
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .video,
            position: .unspecified
        )

        logger.error("Scanning \(discoverySession.devices.count) external video device(s) for sink stream")
        for device in discoverySession.devices {
            logger.error("Inspecting device candidate name=\(device.localizedName, privacy: .public) uid=\(device.uniqueID, privacy: .public)")
            guard let deviceID = getCMIODeviceID(uid: device.uniqueID),
                  let streams = getStreamIDs(deviceID: deviceID),
                  streams.count >= 2,
                  let sinkStreamID = streams.last else {
                logger.error("Rejected device candidate \(device.localizedName, privacy: .public)")
                continue
            }

            logger.error("Falling back to virtual camera candidate \(device.localizedName, privacy: .public) with \(streams.count) streams")
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
            logger.error("Failed to fetch CMIO device list size")
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
            logger.error("Failed to fetch CMIO device list")
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

            var deviceUID: CFString = "" as CFString
            guard CMIOObjectGetPropertyData(
                deviceID,
                &uidAddress,
                0,
                nil,
                uidDataSize,
                &dataUsed,
                &deviceUID
            ) == noErr else {
                continue
            }

            if deviceUID as String == uid {
                logger.error("Matched AVCapture device uid=\(uid, privacy: .public) to CMIO device \(deviceID)")
                return deviceID
            }
        }

        logger.error("No CMIO device matched uid=\(uid, privacy: .public)")
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
            logger.error("Failed to fetch stream list size for device \(deviceID)")
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
            logger.error("Failed to fetch stream list for device \(deviceID)")
            return nil
        }

        logger.error("Device \(deviceID) exposes \(streamIDs.count) stream(s)")
        return streamIDs
    }
}

