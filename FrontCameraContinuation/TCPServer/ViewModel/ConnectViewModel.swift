import AppKit
import Combine
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ConnectViewModel {
    enum Constants {
        static let videoEffectOption = "macVideoEffectOption"
        static let backgroundImagePath = "macBackgroundImagePath"
        static let autoStartReceiver = "macAutoStartReceiver"
    }

    let listenPort: UInt16
    let manager: ServerManager
    let installer: VirtualCameraInstaller
    let ipProvider: IPAddressProvidable
    let defaults: UserDefaults

    private(set) var isRunning = false
    private(set) var isPreviewVisible = false
    private(set) var listenerStatus = "Stopped"
    private(set) var connectionStatus = "Waiting for Listener"
    private(set) var networkAddresses = [String]()
    private(set) var backgroundImage: NSImage?
    
    @ObservationIgnored
    private(set) var scheduleTask: Task<Void, Never>? {
        didSet {
            if let oldValue, !oldValue.isCancelled {
                oldValue.cancel()
            }
        }
    }
    
    private(set)var detectedProperties = false
    
    @ObservationIgnored
    private lazy var pasteboard: NSPasteboard! = {
        NSPasteboard.general
    }()
    
    @ObservationIgnored
    private var networkAddressTask: Task<Void, Never>? {
        didSet {
            if let oldValue, !oldValue.isCancelled {
                oldValue.cancel()
            }
        }
    }
    
    @ObservationIgnored
    private var animatedHelp = false

    @ObservationIgnored
    private var cancellables = Set<AnyCancellable>()

    var autoStartReceiver: Bool {
        didSet {
            guard oldValue != autoStartReceiver else {
                return
            }
            defaults.set(autoStartReceiver, forKey: Constants.autoStartReceiver)
        }
    }

    var videoEffectOption: VideoEffectOption {
        didSet {
            guard oldValue != videoEffectOption else {
                return
            }
            defaults.set(videoEffectOption.rawValue, forKey: Constants.videoEffectOption)
            manager.setVideoEffect(videoEffectOption.effect)
        }
    }

    init(manager: ServerManager = ServerManager(),
         ipProvider: IPAddressProvidable = LocalNetworkAddressProvider(),
         installer: VirtualCameraInstaller = VirtualCameraInstaller(),
         defaults: UserDefaults = .standard,
         listenPort: UInt16 = 9999) {
        self.ipProvider = ipProvider
        self.listenPort = listenPort
        self.manager = manager
        self.installer = installer
        self.defaults = defaults

        let savedOption = defaults.object(forKey: Constants.videoEffectOption) != nil
            ? VideoEffectOption(rawValue: defaults.integer(forKey: Constants.videoEffectOption)) ?? .none
            : .none
        self.videoEffectOption = savedOption
        manager.setVideoEffect(savedOption.effect)

        // Load saved background image
        if let imagePath = defaults.string(forKey: Constants.backgroundImagePath),
           let image = NSImage(contentsOfFile: imagePath) {
            self.backgroundImage = image
            manager.setBackgroundImage(image)
        }

        bind()
    }

    func selectBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        guard let image = NSImage(contentsOf: url) else {
            return
        }

        backgroundImage = image
        defaults.set(url.path, forKey: Constants.backgroundImagePath)
        manager.setBackgroundImage(image)
    }

    func clearBackgroundImage() {
        backgroundImage = nil
        defaults.removeObject(forKey: Constants.backgroundImagePath)
        manager.setBackgroundImage(nil)
    }

    var primaryAddressText: String {
        networkAddresses.first.map { "Mac IP \($0)" } ?? "Find your Mac IP in Wi-Fi settings"
    }

    var primaryAddressForConnection: String {
        networkAddresses.first ?? "your-mac-ip"
    }

    var listenerReady: Bool {
        listenerStatus == "Ready"
    }

    var connectionReady: Bool {
        connectionStatus == "Ready"
    }
    
    var installerNeedsApplicationsMove: Bool {
        installer.installerNeedsApplicationsMove
    }
    
    var installerNeedsApplicationsMoveTextMessage: String? {
        installer.installerNeedsApplicationsMoveTextMessage
    }

    var installerHealthy: Bool {
        installer.installerHealthy
    }
    
    var receiverKeepRunningTitle: String {
        "Keep the receiver running before you open the iPhone app on port \(listenTextPort)."
    }
    
    var receiverTitle: String {
        isRunning
             ? "Open the iPhone app and send video to \(addressText)."
             : "Turn on the receiver first, then connect from the iPhone app using the same Wi-Fi network."
    }

    var previewSubtitle: String {
        if !isPreviewVisible {
            return "Show the preview when you want to verify framing or confirm the incoming feed."
        }

        if connectionReady {
            return "The decoded feed below is what the virtual camera is receiving right now."
        }

        if isRunning {
            return "The receiver is ready. Start streaming from the iPhone to see video here."
        }

        return "This preview will wake up as soon as the Mac receiver is running and the iPhone connects."
    }

    var streamSummary: String {
        if connectionReady {
            return "Live"
        }

        if listenerReady {
            return "Waiting"
        }

        return "Idle"
    }

    var menuBarLabelText: String {
        if connectionReady {
            return "Live"
        }

        if isRunning {
            return "Waiting"
        }

        return "Idle"
    }

    var menuBarSystemImage: String {
        if connectionReady {
            return "video.fill"
        }

        if isRunning {
            return "dot.radiowaves.left.and.right"
        }

        return "video.slash"
    }

    var menuBarStatusText: String {
        if connectionReady {
            return "Streaming is active"
        }

        if listenerReady {
            return "Receiver is waiting for iPhone"
        }

        return "Receiver is stopped"
    }

    var overallStatusTitle: String {
        if connectionReady {
            return "Live Session"
        }

        if listenerReady {
            return "Waiting for iPhone"
        }

        if installerHealthy {
            return "Ready to Listen"
        }

        return "Setup Needed"
    }

    var overallStatusMessage: String {
        if connectionReady {
            return "The Mac is receiving frames and the preview is live."
        }

        if listenerReady {
            return "The receiver is listening. Open the iPhone app and start streaming."
        }

        if installerHealthy {
            return "The virtual camera is prepared. Start the receiver when you are ready."
        }

        return "Move the app to `/Applications`, install the camera, then start the receiver."
    }

    var overallStatusIcon: String {
        if connectionReady {
            return "video.fill"
        }

        if listenerReady {
            return "dot.radiowaves.left.and.right"
        }

        if installerHealthy {
            return "checkmark.shield.fill"
        }

        return "wrench.and.screwdriver.fill"
    }

    func refreshNetworkAddresses() {
        networkAddressTask = .init {
            await refreshNetworkAddresses()
        }
    }
    
    func refreshNetworkAddresses() async {
        let value = await ipProvider.getIPv4Addresses()
        await MainActor.run { [weak self] in
            guard let self, !Task.isCancelled else {
                return
            }
            self.networkAddresses = value
        }
    }

    func showPreview() {
        isPreviewVisible = true
    }

    func hidePreview() {
        isPreviewVisible = false
    }

    func togglePreview() {
        isPreviewVisible.toggle()
    }

    func toggleServer() {
        isRunning ? stopServer() : startServer()
    }

    func startServer() {
        refreshNetworkAddresses()
        
        guard !isRunning else {
            return
        }

        manager.start(port: listenPort)
        isRunning = true
    }

    func stopServer() {
        guard isRunning else {
            return
        }

        manager.stop()
        isRunning = false
        connectionStatus = "Waiting for Listener"
    }
    
    func scheduleDetectProperties() {
        guard scheduleTask == nil, !detectedProperties else {
            return
        }
        
        scheduleTask = Task {
            let result = try? detectProperties()
            handleDetectPropertiesCall(failed: result != true)
        }
    }
    
    private func handleDetectPropertiesCall(failed: Bool) {
        guard failed else {
            return
        }
        
        scheduleTask = nil
        detectedProperties = true
    }
    
    private func detectProperties() throws -> Bool {
        try installer.detectProperties()
    }

    func installCamera() {
        _ = try? installer.activate()
    }

    func uninstallCamera() {
        _ = try? installer.deactivate()
    }
    
    var listenTextPort: String {
        "\(Int(listenPort))"
    }
    
    var listenerTopTitle: String {
        isRunning ? "Listening on \(listenTextPort)" : "Listener stopped"
    }
    
    var listenerTopSystemImage: String {
        isRunning ? "dot.radiowaves.left.and.right" : "pause.circle"
    }
    
    var addressText: String {
        "\(primaryAddressForConnection):\(listenTextPort)"
    }

    func copyConnectionAddress() {
        pasteboard.clearContents()
        pasteboard.setString(addressText, forType: .string)
    }

    private func bind() {
        manager.listenerStatusPublisher
            .sink { [unowned self] value in
                self.listenerStatus = value
            }
            .store(in: &cancellables)

        manager.connectionStateLastPublisher
            .sink { [unowned self] value in
                self.connectionStatus = value
            }
            .store(in: &cancellables)
        
        installer.detectedPropertiesSubject.sink { [unowned self] detectedProperties in
            self.detectedProperties = detectedProperties
            self.scheduleTask = nil
        }.store(in: &cancellables)
    }
    
    func provideQuickSetupViewModel() -> QuickSetupViewModel {
        let shouldAnimate = !animatedHelp
        let viewModel = QuickSetupViewModel(shouldAnimate: shouldAnimate)
        if shouldAnimate {
            viewModel.stepsShownPublisher.sink { [weak self] in
                self?.animatedHelp = true
            }.store(in: &cancellables)
        }
        return viewModel
    }
    
    private func unbind() {
        cancellables.removeAll()
    }
    
    isolated
    deinit {
        networkAddressTask = nil
        unbind()
    }
}
