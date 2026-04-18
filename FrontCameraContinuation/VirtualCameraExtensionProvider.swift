import Foundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import IOKit.audio

// MARK: -

final class VirtualCameraExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {
	
	private(set) var device: CMIOExtensionDevice!
	
	private var streamSource: VirtualCameraExtensionStreamSource!
	
	private let frameReader = SharedFrameReader()
	private let timerQueue = DispatchQueue(label: "virtual-camera-extension.timer")
	private let videoDescription: CMFormatDescription
	
	private var streamingCounter: UInt32 = 0
	
	private var timer: DispatchSourceTimer?
	private var lastSequenceNumber: UInt64 = 0
	
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
		self.videoDescription = formatDescription!
		super.init()
		
		let deviceID = UUID()
		self.device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)
		
		let videoStreamFormat = CMIOExtensionStreamFormat(
			formatDescription: videoDescription,
			maxFrameDuration: VirtualCameraConfiguration.frameDuration,
			minFrameDuration: VirtualCameraConfiguration.frameDuration,
			validFrameDurations: nil
		)
		
		let videoID = UUID()
		streamSource = VirtualCameraExtensionStreamSource(localizedName: "\(localizedName).Video", streamID: videoID, streamFormat: videoStreamFormat, device: device)
		do {
			try device.addStream(streamSource.stream)
		} catch let error {
			fatalError("Failed to add stream: \(error.localizedDescription)")
		}
	}
	
	var availableProperties: Set<CMIOExtensionProperty> {
		
		return [.deviceTransportType, .deviceModel]
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
	
	func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
		
		// Handle settable properties here.
	}
	
	func startStreaming() {
		streamingCounter += 1
		guard timer == nil else { return }
		
		let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
		timer.schedule(deadline: .now(), repeating: .milliseconds(1000 / Int(VirtualCameraConfiguration.frameRate)), leeway: .milliseconds(5))
		timer.setEventHandler { [weak self] in
			self?.pushLatestFrame()
		}
		timer.resume()
		self.timer = timer
	}
	
	func stopStreaming() {
		if streamingCounter > 1 {
			streamingCounter -= 1
		}
		else {
			streamingCounter = 0
			if let timer {
				timer.cancel()
				self.timer = nil
			}
			lastSequenceNumber = 0
		}
	}
	
	private func pushLatestFrame() {
		guard let sharedFrame = frameReader.readFrame(),
			  sharedFrame.sequenceNumber != lastSequenceNumber,
			  let sampleBuffer = makeSampleBuffer(from: sharedFrame.pixelBuffer) else {
			return
		}
		
		lastSequenceNumber = sharedFrame.sequenceNumber
		streamSource.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: sharedFrame.hostTimeInNanoseconds)
	}
	
	private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
		var sampleBuffer: CMSampleBuffer?
		var timingInfo = CMSampleTimingInfo(
			duration: VirtualCameraConfiguration.frameDuration,
			presentationTimeStamp: .invalid,
			decodeTimeStamp: .invalid
		)
		
		let status = CMSampleBufferCreateForImageBuffer(
			allocator: kCFAllocatorDefault,
			imageBuffer: pixelBuffer,
			dataReady: true,
			makeDataReadyCallback: nil,
			refcon: nil,
			formatDescription: videoDescription,
			sampleTiming: &timingInfo,
			sampleBufferOut: &sampleBuffer
		)
		
		guard status == noErr else { return nil }
		return sampleBuffer
	}
}

// MARK: -

final class VirtualCameraExtensionStreamSource: NSObject, CMIOExtensionStreamSource {
	
	private(set) var stream: CMIOExtensionStream!
	
	let device: CMIOExtensionDevice
	
	private let _streamFormat: CMIOExtensionStreamFormat
	
	init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
		
		self.device = device
		self._streamFormat = streamFormat
		super.init()
		self.stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
	}
	
	var formats: [CMIOExtensionStreamFormat] {
		
		return [_streamFormat]
	}
	
	var activeFormatIndex: Int = 0
	
	var availableProperties: Set<CMIOExtensionProperty> {
		
		return [.streamActiveFormatIndex, .streamFrameDuration]
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
		
		// An opportunity to inspect the client info and decide if it should be allowed to start the stream.
		return true
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

// MARK: -

final class VirtualCameraExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
	
	private(set) var provider: CMIOExtensionProvider!
	
	private var deviceSource: VirtualCameraExtensionDeviceSource!
	
	// CMIOExtensionProviderSource protocol methods (all are required)
	
	init(clientQueue: DispatchQueue?) {
		
		super.init()
		
		provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
		deviceSource = VirtualCameraExtensionDeviceSource(localizedName: VirtualCameraConfiguration.deviceName)
		
		do {
			try provider.addDevice(deviceSource.device)
		} catch let error {
			fatalError("Failed to add device: \(error.localizedDescription)")
		}
	}
	
	func connect(to client: CMIOExtensionClient) throws {
		
		// Handle client connect
	}
	
	func disconnect(from client: CMIOExtensionClient) {
		
		// Handle client disconnect
	}
	
	var availableProperties: Set<CMIOExtensionProperty> {
		
		// See full list of CMIOExtensionProperty choices in CMIOExtensionProperties.h
		return [.providerManufacturer]
	}
	
	func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
		
		let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
		if properties.contains(.providerManufacturer) {
			providerProperties.manufacturer = VirtualCameraConfiguration.manufacturerName
		}
		return providerProperties
	}
	
	func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
		
		// Handle settable properties here.
	}
}
