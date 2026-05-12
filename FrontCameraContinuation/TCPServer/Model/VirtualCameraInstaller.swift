import Foundation
import Combine
import AppKit
import SystemExtensions

@MainActor
@Observable
final class VirtualCameraInstaller: NSObject {
    private(set)var status = "Not Installed"
    private static let applicationPathPrefix = "/Applications"
    
    enum State {
        case installed
        case uninstalled
        case waitingForActivation
    }
    
    enum RequestState {
        case installing
        case uninstalling
        case fetchingProperties
    }
    
    private var isRunning = false
    private var error: Error?
    private var state: State?
    
    private var requestState: RequestState?
    
    let manager: OSSystemExtensionManager
    init(manager: OSSystemExtensionManager = .shared) {
        self.manager = manager
    }
    
    private func extensionIdentifier() throws -> String {
        guard let identifier = Bundle.main.bundleIdentifier else {
            throw NSError(domain: "camera.installer", code: .min, userInfo: [NSLocalizedFailureErrorKey: "No Bundle ID"])
        }
     
        return identifier.appending(".Cam2Mac")
    }

    
    private func submitRequest(_ state: RequestState, identifier: String) {
        let request: OSSystemExtensionRequest
        let text: String
        switch state {
        case .fetchingProperties:
            request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: identifier,
                                                                 queue: .main)
            text = "Gathering properties"
        case .installing:
            request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier,
                                                                 queue: .main)
            text = "Installing"
        case .uninstalling:
            request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: identifier,
                                                                   queue: .main)
            text = "Uninstalling"
        }
        requestState = state
        status = text
        request.delegate = self
        isRunning = true
        manager.submitRequest(request)
    }
    
    func activate() throws {
        guard isRunningFromSystemApplicationsFolder else {
            if openInstalledAppIfAvailable() {
                status = "Opened \(Self.applicationPathPrefix) copy. Install the extension from that app."
            } else {
                status = "Run \(Self.applicationPathPrefix)/Cam2Mac.app to install the extension."
            }
            return
        }
        
        let identifier = try extensionIdentifier()
        submitRequest(.installing, identifier: identifier)
    }
    
    func detectProperties() throws {
        guard isRunningFromSystemApplicationsFolder else {
            if openInstalledAppIfAvailable() {
                status = "Opened \(Self.applicationPathPrefix) copy. Install the extension from that app."
            } else {
                status = "Run \(Self.applicationPathPrefix)/Cam2Mac.app to install the extension."
            }
            return
        }
        
        let identifier = try extensionIdentifier()
        submitRequest(.fetchingProperties, identifier: identifier)
    }
    
    func deactivate() throws {
        guard isRunningFromSystemApplicationsFolder else {
            if openInstalledAppIfAvailable() {
                status = "Opened \(Self.applicationPathPrefix) copy. Uninstall the extension from that app."
            } else {
                status = "Run \(Self.applicationPathPrefix)/Cam2Mac.app to uninstall the extension."
            }
            return
        }

        let identifier = try extensionIdentifier()
        submitRequest(.uninstalling, identifier: identifier)
    }

    private var isRunningFromSystemApplicationsFolder: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("\(Self.applicationPathPrefix)/")
    }

    private func openInstalledAppIfAvailable() -> Bool {
        let installedURL = URL(fileURLWithPath: "\(Self.applicationPathPrefix)/\(Bundle.main.bundleURL.lastPathComponent)")
        guard FileManager.default.fileExists(atPath: installedURL.path) else {
            return false
        }

        return NSWorkspace.shared.open(installedURL)
    }
    
    var installerNeedsApplicationsMove: Bool {
        status.contains(Self.applicationPathPrefix)
    }
    
    var installerHealthy: Bool {
        // status == "Installed" || status == "Installed After Restart"
        status.hasPrefix("Installed") // TODO: use some state...
    }
}

// MARK: - OSSystemExtensionRequestDelegate
extension VirtualCameraInstaller: OSSystemExtensionRequestDelegate {
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Waiting For User Approval"
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        self.isRunning = false
        self.error = nil
        
        switch result {
        case .completed:
            status = "Installed"
        case .willCompleteAfterReboot:
            status = "Installed After Restart"
        @unknown default:
            status = ""
        }
    }
    
    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        self.isRunning = false
        self.error = nil
        
        guard !properties.isEmpty else {
            return
        }
        let isEnabled = properties.contains { $0.isEnabled }
        if isEnabled {
            status = "Installed"  // should be installed.
        } else if properties.contains(where: { $0.isUninstalling }) {
            status = "Removing"
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        self.isRunning = false
        self.error = error
        
        let nsError = error as NSError
        #if DEBUG
            status = "Failed (\(nsError.domain) \(nsError.code)): \(nsError.localizedDescription)"
        #else
            status = "Failed \(nsError.localizedDescription)"
        #endif
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }
}
