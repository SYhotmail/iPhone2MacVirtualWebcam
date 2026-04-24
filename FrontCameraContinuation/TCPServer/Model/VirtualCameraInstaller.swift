import Foundation
import Combine
import AppKit
import SystemExtensions

@MainActor
@Observable
final class VirtualCameraInstaller: NSObject {
    private(set) var status = "Not Installed"
    private static let applicationPathPrefix = "/Applications"
    
    func activate() {
        guard isRunningFromSystemApplicationsFolder else {
            if openInstalledAppIfAvailable() {
                status = "Opened \(Self.applicationPathPrefix) copy. Install the extension from that app."
            } else {
                status = "Run \(Self.applicationPathPrefix)/Cam2Mac.app to install the extension."
            }
            return
        }

        status = "Requesting Activation"

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: VirtualCameraConfiguration.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    
    func deactivate() {
        guard isRunningFromSystemApplicationsFolder else {
            if openInstalledAppIfAvailable() {
                status = "Opened \(Self.applicationPathPrefix) copy. Install the extension from that app."
            } else {
                status = "Run \(Self.applicationPathPrefix)/Cam2Mac.app to install the extension."
            }
            return
        }

        status = "Requesting Deactivation"

        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: VirtualCameraConfiguration.extensionBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private var isRunningFromSystemApplicationsFolder: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("\(Self.applicationPathPrefix)/")
    }

    private func openInstalledAppIfAvailable() -> Bool {
        let installedURL = URL(fileURLWithPath: "\(Self.applicationPathPrefix)/\(Bundle.main.bundleURL.lastPathComponent)")
        guard FileManager.default.fileExists(atPath: installedURL.path) else {
            return false
        }

        NSWorkspace.shared.open(installedURL)
        return true
    }
}

extension VirtualCameraInstaller: OSSystemExtensionRequestDelegate {
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Waiting For User Approval"
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            status = "Installed"
        case .willCompleteAfterReboot:
            status = "Installed After Restart"
        @unknown default:
            status = "Finished"
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        status = "Activation Failed (\(nsError.domain) \(nsError.code)): \(nsError.localizedDescription)"
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }
}
