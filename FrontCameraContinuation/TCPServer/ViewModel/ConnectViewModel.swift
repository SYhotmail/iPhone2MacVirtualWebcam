import Foundation
import Combine
import AppKit
import Observation

@MainActor
@Observable
final class ConnectViewModel {
    let listenPort: UInt16
    let manager: ServerManager
    let installer: VirtualCameraInstaller

    private(set) var isRunning = false
    private(set) var listenerStatus = "Stopped"
    private(set) var connectionStatus = "Waiting for Listener"
    private(set) var networkAddresses = LocalNetworkAddressProvider.ipv4Addresses()

    private var cancellables = Set<AnyCancellable>()

    init(listenPort: UInt16 = 9999,
         manager: ServerManager,
         installer: VirtualCameraInstaller) {
        self.listenPort = listenPort
        self.manager = manager
        self.installer = installer
        bind()
    }

    convenience init(listenPort: UInt16 = 9999) {
        self.init(
            listenPort: listenPort,
            manager: ServerManager(),
            installer: VirtualCameraInstaller()
        )
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
        installer.status.contains("/Applications")
    }

    var installerHealthy: Bool {
        installer.status == "Installed" || installer.status == "Installed After Restart"
    }

    var previewSubtitle: String {
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
        networkAddresses = LocalNetworkAddressProvider.ipv4Addresses()
    }

    func toggleServer() {
        if isRunning {
            manager.stop()
            isRunning = false
            connectionStatus = "Waiting for Listener"
        } else {
            manager.start(port: listenPort)
            isRunning = true
            refreshNetworkAddresses()
        }
    }

    func installCamera() {
        installer.activate()
    }

    func uninstallCamera() {
        installer.deactivate()
    }

    func copyConnectionAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(primaryAddressForConnection):\(listenPort)", forType: .string)
    }

    private func bind() {
        manager.listenerStatusPublisher
            .sink { [weak self] value in
                self?.listenerStatus = value
            }
            .store(in: &cancellables)

        manager.connectionStateLastPublisher
            .sink { [weak self] value in
                self?.connectionStatus = value
            }
            .store(in: &cancellables)
    }
}
