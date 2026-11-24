import SwiftUI
import AVFoundation
import Combine
import UIKit
import os
import Transport

@Observable
final class ContentViewModel {
    enum StreamStatus: Equatable {
        case idle
        case connecting
        case waitingForReceiver
        case streaming
        case attentionNeeded
        /// No paired Mac, or the Mac refused this iPhone's credentials.
        case pairingNeeded
    }

    nonisolated
    enum Constants {
        /// Optional fixed address overriding Bonjour discovery.
        static let manualHostKey = "manualHost"
        static let portKey = "port"
        static let streamSize = "streamSize"
        static let cameraPosition = "cameraPosition"
        static let autoStartStreaming = "autoStartStreaming"
        static let defaultPortString = "9999"
        static let defaultPort: UInt16 = 9999
    }

    // Inputs persisted by the view
    /// Leave empty to find the paired Mac over Bonjour.
    var manualHost: String {
        didSet {
            guard oldValue != manualHost else {
                return
            }
            defaults.set(manualHost, forKey: Constants.manualHostKey)
        }
    }
    
    var port: String {
        didSet {
            guard oldValue != port else {
                return
            }
            defaults.set(port, forKey: Constants.portKey)
        }
    }

    // UI state
    var streamSize: StreamSize {
        didSet {
            guard oldValue != streamSize else {
                return
            }
            defaults.set(streamSize.rawValue, forKey: Constants.streamSize)
            preparePreview()
        }
    }
    
    var cameraPosition: CameraPosition {
        didSet {
            guard oldValue != cameraPosition else {
                return
            }
            defaults.set(cameraPosition.rawValue, forKey: Constants.cameraPosition)
            preparePreview()
        }
    }

    var autoStartStreaming: Bool {
        didSet {
            guard oldValue != autoStartStreaming else {
                return
            }
            defaults.set(autoStartStreaming, forKey: Constants.autoStartStreaming)
        }
    }

    var showFullScreenPreview = false
    var isScanningPairingCode = false
    /// Code found by the scanner; shown for confirmation once the scanner has fully closed.
    @ObservationIgnored
    private var scannedInvitation: PairingInvitation?
    /// A scanned code waiting for the user to confirm pairing.
    var invitationToConfirm: PairingInvitation?
    private(set) var pairedMac: PairedMac?
    /// Reason the Mac gave for refusing this iPhone.
    private(set) var rejectionReason: String?
    /// Credentials being registered with a Mac; saved once the Mac accepts them.
    private var pendingPairing: (mac: PairedMac, hello: PairingHello)?
    
    private var cancellables = Set<AnyCancellable>()
    private(set)var isPreviewVisible = false
    
    @ObservationIgnored
    let previewAnimation = ContentViewModel.defaultPreviewAnimation
    
    static let defaultPreviewAnimation = Animation.spring(response: 0.38, dampingFraction: 0.88)
    
    private(set) var isStreamingRequested = false
    private(set) var streamStatus: StreamStatus = .idle
    
    private let launchCoordinator: StreamingLaunchCoordinator
    
    private(set)var isStreaming = false {
        didSet {
            guard oldValue != isStreaming else {
                return
            }
            Self.changeIdleTimer(isStreaming)
        }
    }
    
    init(cameraStreamer: CameraStreamer,
         pipController: CameraPIPManager = .init(),
         launchCoordinator: StreamingLaunchCoordinator = .shared,
         defaults: UserDefaults = .standard) {
        self.cameraStreamer = cameraStreamer
        self.launchCoordinator = launchCoordinator
        self.defaults = defaults
        self.pipController = pipController
        manualHost = defaults.string(forKey: Constants.manualHostKey) ?? ""
        port = defaults.string(forKey: Constants.portKey) ?? Constants.defaultPortString
        let pairedMac = PairedMacStore.load()
        self.pairedMac = pairedMac
        streamStatus = pairedMac == nil ? .pairingNeeded : .idle
        streamSize = defaults.object(forKey: Constants.streamSize) != nil ? StreamSize(rawValue: defaults.integer(forKey: Constants.streamSize)) ?? .hd720 : .hd720
        cameraPosition = defaults.object(forKey: Constants.cameraPosition) != nil ? CameraPosition(rawValue: defaults.integer(forKey: Constants.cameraPosition)) ?? .front : .front
        autoStartStreaming = defaults.bool(forKey: Constants.autoStartStreaming)
        bind()
    }

    convenience init(
        pipController: CameraPIPManager = .init(),
        launchCoordinator: StreamingLaunchCoordinator = .shared,
        defaults: UserDefaults = .standard
    ) throws {
        let cameraStreamer = try CameraStreamer()
        self.init(
            cameraStreamer: cameraStreamer,
            pipController: pipController,
            launchCoordinator: launchCoordinator,
            defaults: defaults
        )
    }

    func checkAutoStart() {
        if autoStartStreaming && !isStreamingRequested {
            startStreaming()
        }
    }
    
    nonisolated

    let pipController: CameraPIPManager
    // Streaming backend
    let cameraStreamer: CameraStreamer
    let defaults: UserDefaults

    var previewSession: AVCaptureSession {
        cameraStreamer.session
    }

    var pendingStartRequestID: String? {
        launchCoordinator.pendingStartRequestID
    }

    private(set)var cameraPreviewId = UInt128(0)
    
    func handleFullScreenPreviewDismiss() {
        assert(isPreviewVisible)
        cameraPreviewId += 1
    }
    
    private func preparePreview() {
        cameraStreamer.preparePreview(position: cameraPosition.avPosition,
                                      preset: streamSize.sessionPreset)
    }

    var shouldAttachPreviewLayer: Bool {
        isPreviewVisible || isStreamingRequested
    }
    
    var isStreamingText: String {
        switch streamStatus {
        case .idle:
            return "Camera is warmed up so you can frame the shot before sending it to your Mac."
        case .connecting:
            return "Trying to reach your Mac now. Keep the app open until the connection turns live."
        case .waitingForReceiver:
            return "The Mac receiver is offline right now. This iPhone will keep capturing and retry automatically until the Mac app is ready."
        case .streaming:
            return "Sending the camera feed to your Mac right now."
        case .attentionNeeded:
            return "We lost the connection before the stream went live. Make sure the Mac receiver is running on the same Wi-Fi, then try again."
        case .pairingNeeded:
            return rejectionReason ?? "Pair this iPhone with your Mac: click Pair iPhone… in the Mac app and scan the code."
        }
    }

    var statusTitle: String {
        switch streamStatus {
        case .idle:
            return "Ready"
        case .connecting:
            return "Connecting"
        case .waitingForReceiver:
            return "Waiting for Mac"
        case .streaming:
            return "Live"
        case .attentionNeeded:
            return "Check Connection"
        case .pairingNeeded:
            return "Pairing Needed"
        }
    }

    var statusDetail: String {
        switch streamStatus {
        case .idle:
            return "Preview is available and the stream is not running."
        case .connecting:
            return "Trying to connect to your Mac receiver."
        case .waitingForReceiver:
            return "The receiver is not accepting connections yet. We will keep retrying in the background."
        case .streaming:
            return "Your Mac is receiving the camera feed."
        case .attentionNeeded:
            return "The Mac receiver did not accept the stream."
        case .pairingNeeded:
            return "Scan the pairing code shown on your Mac."
        }
    }

    var primaryActionTitle: String {
        switch streamStatus {
        case .connecting, .waitingForReceiver, .streaming:
            return "Stop Stream"
        case .attentionNeeded:
            return "Retry Stream"
        case .idle:
            return "Start Stream"
        case .pairingNeeded:
            return "Pair with Mac"
        }
    }

    var primaryActionSymbol: String {
        switch streamStatus {
        case .connecting, .waitingForReceiver, .streaming:
            return "stop.fill"
        case .attentionNeeded:
            return "arrow.clockwise"
        case .idle:
            return "bolt.fill"
        case .pairingNeeded:
            return "qrcode.viewfinder"
        }
    }

    // MARK: - Actions

    func togglePreviewVisibility() {
        if !isPreviewVisible, !isStreaming {
            preparePreview()
        }
        isPreviewVisible.toggle()
    }
    
    func toggleStreaming() {
        if streamStatus == .pairingNeeded {
            beginPairingScan()
        } else if isStreamingRequested {
            stopStreaming()
        } else {
            startStreaming()
        }
    }
    
    private func resetVideoContent() {
        pipController.resetVideoContent()
    }

    func startStreaming() {
        guard let destination = makeDestination() else {
            streamStatus = .pairingNeeded
            return
        }

        resetVideoContent()
        rejectionReason = nil
        isStreamingRequested = true
        streamStatus = .connecting
        let didStart = cameraStreamer.startStreaming(
            to: destination,
            position: cameraPosition.avPosition,
            preset: streamSize.sessionPreset
        )

        if !didStart {
            isStreamingRequested = false
            isStreaming = false
            streamStatus = .attentionNeeded
        }
    }
    
    private func makeDestination() -> FrameStreamClient.Destination? {
        guard let (mac, hello) = pendingPairing ?? pairedMac.map({ ($0, $0.hello) }) else {
            return nil
        }
        let trimmedHost = manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            return .service(named: mac.serviceName, pinnedFingerprint: mac.fingerprint, hello: hello)
        }
        return .host(
            trimmedHost,
            port: UInt16(port) ?? Constants.defaultPort,
            pinnedFingerprint: mac.fingerprint,
            hello: hello
        )
    }

    // MARK: - Pairing

    /// Opens the QR scanner, releasing the camera it needs.
    func beginPairingScan() {
        stopStreaming()
        cameraStreamer.stopCapture()
        isScanningPairingCode = true
    }

    /// Handles an opened `cam2mac://` link by asking the user to confirm.
    func handlePairingURL(_ url: URL) {
        guard let invitation = PairingInvitation(url: url) else {
            pairingLogger.error("Ignored invalid pairing link")
            return
        }
        if isScanningPairingCode {
            handleScannedInvitation(invitation)
        } else {
            invitationToConfirm = invitation
        }
    }

    func handleScannedInvitation(_ invitation: PairingInvitation) {
        scannedInvitation = invitation
        isScanningPairingCode = false
    }

    /// Called after the scanner cover is gone; SwiftUI drops alerts presented while a cover is dismissing.
    func pairingScannerDidDismiss() {
        if let scannedInvitation {
            self.scannedInvitation = nil
            invitationToConfirm = scannedInvitation
        } else {
            preparePreview()
        }
    }

    /// Registers this iPhone with the confirmed Mac by connecting with the one-time token.
    func confirmPairing(_ invitation: PairingInvitation) {
        invitationToConfirm = nil
        stopStreaming()
        pairingLogger.info("Pairing with \(invitation.serviceName, privacy: .public)")
        let mac = PairedMac(invitation: invitation)
        pendingPairing = (mac, .pair(
            token: invitation.token,
            clientID: mac.clientID,
            secret: mac.secret,
            deviceName: UIDevice.current.name
        ))
        startStreaming()
    }

    func unpair() {
        stopStreaming()
        pendingPairing = nil
        PairedMacStore.remove()
        pairedMac = nil
        streamStatus = .pairingNeeded
    }

    private func completePendingPairing() {
        guard let pendingPairing else {
            return
        }
        let saved = PairedMacStore.save(pendingPairing.mac)
        pairingLogger.info("Paired with \(pendingPairing.mac.serviceName, privacy: .public); saved=\(saved)")
        pairedMac = pendingPairing.mac
        self.pendingPairing = nil
    }

    func removePendingRequest() {
        launchCoordinator.removePendingRequest()
    }

    /// Queues a one-shot request for the foreground app to start streaming.
    /// Starts streaming in response to a Siri or Shortcuts request using the saved destination.
    func startStreamingFromAppIntent() {
        guard launchCoordinator.consumePendingStartRequest() != nil, !isStreamingRequested else {
            return
        }

        startStreaming()
    }
    
    func handleScenePhase(_ newValue: ScenePhase) {
        guard newValue == .active else {
            if case .background = newValue {
                removePendingRequest()
            }
            return
        }
        pipController.stopPIP()
    }

    func stopStreaming() {
        resetVideoContent()
        cameraStreamer.stopStreaming()
        isStreamingRequested = false
        isStreaming = false
        streamStatus = pairedMac == nil && pendingPairing == nil ? .pairingNeeded : .idle
    }

    private func bind() {
        cameraStreamer.isConnectedPublisher
            .onMainAnyPublisher()
            .sink { [weak self] isConnected in
                self?.isStreaming = isConnected
            }
            .store(in: &cancellables)

        cameraStreamer.connectionStatusPublisher
            .onMainAnyPublisher()
            .sink { [weak self] status in
                self?.applyConnectionStatus(status)
            }
            .store(in: &cancellables)

        cameraStreamer.isStreamingRequestedPublisher
            .onMainAnyPublisher()
            .sink { [weak self] isRequested in
                self?.isStreamingRequested = isRequested
            }
            .store(in: &cancellables)
    }

    func supportedCameraStreamSizes() -> [StreamSize] {
        StreamSize.allCases.filter { cameraStreamer.session.canSetSessionPreset($0.sessionPreset) }
    }
    
    func toggleCameraPosition() {
        switch cameraPosition {
        case .front:
            cameraPosition = .back
        case .back:
            cameraPosition = .front
        }
    }
    

    private static func changeIdleTimer(_ isIdleTimerDisabled: Bool) {
        Task { @MainActor in
            UIApplication.shared.isIdleTimerDisabled = isIdleTimerDisabled
        }
    }

    private func applyConnectionStatus(_ status: CameraStreamer.ConnectionStatus) {
        pairingLogger.debug("Connection status \(String(describing: status), privacy: .public)")
        switch status {
        case .idle:
            if !isStreamingRequested && !isStreaming && streamStatus != .pairingNeeded {
                streamStatus = .idle
            }
        case .connecting:
            if streamStatus != .waitingForReceiver {
                streamStatus = .connecting
            }
        case .connected:
            completePendingPairing()
            streamStatus = .streaming
        case .failed:
            isStreaming = false
            streamStatus = isStreamingRequested ? .waitingForReceiver : .attentionNeeded
        case .rejected(let reason):
            pairingLogger.error("Mac rejected this iPhone: \(reason ?? "-", privacy: .public)")
            pendingPairing = nil
            cameraStreamer.stopStreaming()
            isStreamingRequested = false
            isStreaming = false
            rejectionReason = reason
            streamStatus = .pairingNeeded
        @unknown default:
            isStreaming = false
            streamStatus = .attentionNeeded
        }
    }
}
