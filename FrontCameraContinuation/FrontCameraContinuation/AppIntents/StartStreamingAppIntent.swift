import AppIntents
import Foundation
import Observation


@Observable
final class StreamingLaunchCoordinator {
    static let shared = StreamingLaunchCoordinator()

    nonisolated
    enum Constants {
        static let pendingStartRequestIDKey = "pendingStartRequestID"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var pendingStartRequestID: String? {
        defaults.string(forKey: Constants.pendingStartRequestIDKey)
    }

    /// Queues a request for the foreground app to start streaming.
    func requestStartStreaming() {
        defaults.set(UUID().uuidString, forKey: Constants.pendingStartRequestIDKey)
    }

    /// Returns and clears the pending start request so it only runs once.
    func consumePendingStartRequest() -> String? {
        guard let pendingStartRequestID else {
            return nil
        }
        
        removePendingRequest()

        return pendingStartRequestID
    }
    
    func removePendingRequest() {
        defaults.removeObject(forKey: Constants.pendingStartRequestIDKey)
    }
}

struct StartStreamingAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Streaming on Cam2Mac"
    static let description = IntentDescription("Opens Cam2Mac on iPhone and starts sending the camera feed to your paired Mac.")
    static let openAppWhenRun = true
    
    @MainActor
    var coordinator: StreamingLaunchCoordinator { .shared }
    
    func perform() async throws -> some IntentResult {
        guard PairedMacStore.load() != nil else {
            return .result()
        }

        await coordinator.requestStartStreaming()

        return .result()
    }
    
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .foreground(.immediate)
    }
}

struct Cam2MacAppShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartStreamingAppIntent(),
            phrases: [
                "Start Cam2Mac stream with \(.applicationName)",
                "Start Cam2Mac streaming in \(.applicationName)",
                "Begin Cam2Mac stream with \(.applicationName)",
                "Start streaming with \(.applicationName)",
                "Start streaming on \(.applicationName)",
                "Start the stream in \(.applicationName)",
                "Begin streaming with \(.applicationName)",
                "Begin the stream in \(.applicationName)",
                "Start Streaming \(.applicationName)",
                "Start Cam2Mac streaming with \(.applicationName)",
                "Start the Cam2Mac stream in \(.applicationName)"
            ],
            shortTitle: "Start Streaming",
            systemImageName: "dot.radiowaves.left.and.right"
        )
    }
}
