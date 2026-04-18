import Foundation
import Combine
import AppKit
import SystemExtensions

@MainActor
final class VirtualCameraInstaller: NSObject, ObservableObject {
    @Published private(set) var status = "Not Installed"

    func activate() {
        guard isRunningFromSystemApplicationsFolder else {
            if openInstalledAppIfAvailable() {
                status = "Opened /Applications copy. Install the extension from that app."
            } else {
                status = "Run /Applications/TCPServer.app to install the extension."
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

    private var isRunningFromSystemApplicationsFolder: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
    }

    private func openInstalledAppIfAvailable() -> Bool {
        let installedURL = URL(fileURLWithPath: "/Applications/\(Bundle.main.bundleURL.lastPathComponent)")
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
