import Foundation
import Combine
import AppKit
import SystemExtensions

@MainActor
@Observable
final class VirtualCameraInstaller: NSObject {
    private static let applicationPathPrefix = "/Applications"
    
    enum ComponentState: CustomStringConvertible {
        case installing(needReboot: Bool)
        case installed(enabled: Bool?)
        case uninstalling(waitingForApproval: Bool)
        case uninstalled
        
        var isInstallationRelated: Bool {
            if case .installed = self {
                return true
            }
            
            if case .installing = self {
                return true
            }
            
            return false
        }
        
        var description: String {
            switch self {
            case .installed(let enabled):
                return "Installed \(enabled.map(\.description) ?? "")"
            case .installing(let needReboot):
                return "Installing \(needReboot ? "Reboot" : "")"
            case .uninstalled:
                return "Uninstalled"
            case .uninstalling(let waitingForApproval):
                return "Uninstalling \(waitingForApproval ? "Waiting for approval" : "")"
            }
        }
    }
    
    enum RequestAction {
        case completed(needReboot: Bool)
    }
    
    enum RequestType: CustomStringConvertible {
        case installing
        case uninstalling
        case fetchingProperties
        
        var description: String {
            switch self {
            case .fetchingProperties:
                return "Gathering properties"
            case .installing:
                return "Installing"
            case .uninstalling:
                return "Uninstalling"
            }
        }
    }
    
    private(set)var status: String?
    private var isRunning = false
    @ObservationIgnored
    private(set)var detectedPropertiesSubject = CurrentValueSubject<Bool, Never>(false)
    private var componentState: ComponentState?
    
    private var requestType: RequestType? {
        didSet {
            isRunning = true
            status = requestType?.description
        }
    }
    
    private var requestResult: Result<RequestAction, Error>? {
        didSet {
            isRunning = false
        }
    }
    
    let manager: OSSystemExtensionManager
    let fileManager: FileManager
    let bundle: Bundle
    let workspace: NSWorkspace
    let appName: String
    
    init(manager: OSSystemExtensionManager = .shared,
         fileManager: FileManager = .default,
         bundle: Bundle = .main,
         workspace: NSWorkspace = .shared) {
        self.manager = manager
        self.fileManager = fileManager
        self.bundle = bundle
        self.workspace = workspace
        let bundleURL = bundle.bundleURL
        let name = bundleURL.lastPathComponent
        self.appName = name
    }
    
    private func extensionIdentifier() throws -> String {
        guard let identifier = bundle.bundleIdentifier else {
            throw NSError(domain: "camera.installer", code: .min, userInfo: [NSLocalizedFailureErrorKey: "No Bundle ID"])
        }
     
        let dot = "."
        var name = appName
        if let firstPart = name.split(separator: dot).first {
            name = String(firstPart)
        }
        
        return identifier.appending(dot + name)
    }

    
    private func submitRequest(_ requestType: RequestType, identifier: String) {
        let request: OSSystemExtensionRequest
        switch requestType {
        case .fetchingProperties:
            request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: identifier,
                                                                 queue: .main)
        case .installing:
            request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: identifier,
                                                                 queue: .main)
        case .uninstalling:
            request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: identifier,
                                                                   queue: .main)
        }
        
        self.requestType = requestType
        
        request.delegate = self
        manager.submitRequest(request)
    }
    
    private var bundleURL: URL {
        bundle.bundleURL
    }

    private var isRunningFromSystemApplicationsFolder: Bool {
        bundleURL.standardizedFileURL.path.hasPrefix("\(Self.applicationPathPrefix)/")
    }

    private func urlOfAppInApplications() -> URL? {
        let installedURL = URL(fileURLWithPath: "\(Self.applicationPathPrefix)/\(bundleURL.lastPathComponent)")
        let path = installedURL.path()
        let result = fileManager.fileExists(atPath: path) && fileManager.isExecutableFile(atPath: path) ? installedURL : nil
        return result
    }
    
    private func makeRequest(type requestType: RequestType) throws -> Bool {
        var flag = isRunningFromSystemApplicationsFolder
#if DEBUG
        if !flag, requestType == .fetchingProperties {
            flag = urlOfAppInApplications() != nil // allow to run debug application...
        }
#endif
        guard flag else {
            let isOpened = urlOfAppInApplications().flatMap { workspace.open($0) } == true
            status = statusForOpenedApp(isOpened: isOpened, installed: requestType != .uninstalling)
            return false
        }
        
        let identifier = try extensionIdentifier()
        submitRequest(requestType, identifier: identifier)
        return true
    }
    
    @discardableResult
    func activate() throws -> Bool {
        try makeRequest(type: .installing)
    }
    
    @discardableResult
    func detectProperties() throws -> Bool {
        try makeRequest(type: .fetchingProperties)
    }
    
    @discardableResult
    func deactivate() throws -> Bool {
        try makeRequest(type: .uninstalling)
    }
    
    private func statusForOpenedApp(isOpened: Bool, installed: Bool) -> String {
        let text = installed ? "Install" : "Uninstall"
        if isOpened {
            return "Opened \(Self.applicationPathPrefix) copy. \(text) the extension from that app."
        } else {
            return "Run \(Self.applicationPathPrefix)/\(appName) to \(text.lowercased()) the extension."
        }
    }
    
    var installerNeedsApplicationsMove: Bool {
        !isRunningFromSystemApplicationsFolder && componentState == nil && urlOfAppInApplications() != nil
    }
    
    var installerNeedsApplicationsMoveTextMessage: String? {
        guard installerNeedsApplicationsMove else {
            return nil
        }
        return "Open the copy in `\(Self.applicationPathPrefix)` before installing the system extension."
    }
    
    var installerHealthy: Bool {
        componentState?.isInstallationRelated == true
        
    }
}

// MARK: - OSSystemExtensionRequestDelegate
extension VirtualCameraInstaller: OSSystemExtensionRequestDelegate {
    static var awaitingApproval: String {
        "Awaiting Approval"
    }
    
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        requestResult = nil // waiting for Approval..
        status = Self.awaitingApproval
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        var needReboot: Bool?
        
        switch result {
        case .completed:
            needReboot = false
        case .willCompleteAfterReboot:
            needReboot = true
        @unknown default:
            assert(false)
        }
        
        requestResult = needReboot.flatMap { .success(.completed(needReboot: $0)) }
        
        guard let needReboot, let requestType else {
            return
        }
        
        switch requestType {
        case .installing:
            componentState = needReboot ? .installing(needReboot: true) : .installed(enabled: true)
        case .uninstalling:
            componentState = needReboot ? .uninstalling(waitingForApproval: false) : .uninstalled
        default:
            return
        }
        
        status = componentState?.description
    }
    
    static func bundleShortVersions(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }
    
    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        isRunning = false
        status = nil
        detectedPropertiesSubject.value = true
        
        let bundleShortVersion = bundle.bundleShortVersionString
        let bundleVersion = bundle.buildVersionString
        
        let property = properties.first { $0.bundleVersion == bundleVersion && $0.bundleShortVersion == bundleShortVersion }
        
        guard let property else {
            return
        }
        
        let isEnabled = property.isEnabled
        let isAwaitingUserApproval = property.isAwaitingUserApproval
        let isUninstalling = property.isUninstalling
        
        if isUninstalling {
            status = "Removing"
            componentState = .uninstalling(waitingForApproval: isAwaitingUserApproval)
        } else {
            
            if isAwaitingUserApproval {
                status = Self.suffixed(text: "Installing", with: Self.awaitingApproval)
                componentState = .installing(needReboot: false)
            } else {
                status = isEnabled ? "Installed" : Self.suffixed(text: "Installed", with: "disabled")
                componentState = .installed(enabled: isEnabled)
            }
        
        }
    }
    
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        requestResult = .failure(error)
        status = Self.statusFromError(error)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }
    
    // MARK: - Private
    
    nonisolated
    private static func suffixed(text string: String?, with suffix: String) -> String {
        [string, wrapInBrackets(suffix.capitalized)].compactMap { $0 }.joined(separator: " ")
    }
    
    nonisolated
    private static func wrapInBrackets(_ string: String) -> String {
        return "(" + string + ")"
    }
    
    nonisolated
    private static func statusFromError(_ error: Error) -> String {
        let nsError = error as NSError
        let middlePart: String
#if DEBUG
        middlePart = Self.wrapInBrackets("\(nsError.domain) \(nsError.code)")
#else
        middlePart = ""
#endif
        return "Failed \(middlePart) \(nsError.localizedDescription)"
    }
}
