import AVKit
import SwiftUI

@MainActor
final class CameraPreviewPIPController: NSObject, AVPictureInPictureControllerDelegate {
    private weak var sourceView: PreviewView?
    private var session: AVCaptureSession?
    private var isStreaming = false
    private var startAttemptWorkItem: DispatchWorkItem? {
        didSet {
            guard let oldValue, oldValue !== startAttemptWorkItem else {
                return
            }
            oldValue.cancel()
        }
    }

    private lazy var pictureInPictureViewController: AVPictureInPictureVideoCallViewController = {
        let controller = AVPictureInPictureVideoCallViewController()
        controller.preferredContentSize = CGSize(width: 1080, height: 1920)
        controller.view.backgroundColor = .black
        controller.view.addSubview(pictureInPicturePreviewView)
        pictureInPicturePreviewView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pictureInPicturePreviewView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            pictureInPicturePreviewView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            pictureInPicturePreviewView.topAnchor.constraint(equalTo: controller.view.topAnchor),
            pictureInPicturePreviewView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
        ])
        return controller
    }()

    private lazy var pictureInPicturePreviewView: PreviewView = {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }()

    private var pictureInPictureController: AVPictureInPictureController?

    func updateSession(_ session: AVCaptureSession) {
        guard self.session !== session else {
            return
        }
        self.session = session
        pictureInPicturePreviewView.session = session
        pictureInPicturePreviewView.refreshRotationCoordinator()
        rebuildControllerIfNeeded()
    }

    func attachSourceView(_ sourceView: PreviewView) {
        guard self.sourceView !== sourceView else {
            return
        }
        self.sourceView = sourceView
        rebuildControllerIfNeeded()
    }

    func clearSourceView() {
        sourceView = nil
        pictureInPictureController = nil
    }

    func updateStreamingState(isStreaming: Bool) {
        self.isStreaming = isStreaming
        pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = isStreaming

        if isStreaming {
            activateAudioSession()
        } else {
            cancelPendingStart()
            pictureInPictureController?.stopPictureInPicture()
            deactivateAudioSession()
        }
    }

    func handleScenePhaseChange(_ scenePhase: ScenePhase) {
        guard isStreaming else {
            return
        }

        switch scenePhase {
        case .inactive:
            requestStartPictureInPicture()
        case .background:
            requestStartPictureInPicture()
        default:
            break
        }
    }

    private func rebuildControllerIfNeeded() {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let sourceView else {
            pictureInPictureController = nil
            return
        }

        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: pictureInPictureViewController
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.canStartPictureInPictureAutomaticallyFromInline = isStreaming
        controller.delegate = self
        pictureInPictureController = controller
    }

    private func requestStartPictureInPicture() {
        cancelPendingStart()
        attemptStartPictureInPicture(remainingAttempts: 8)
    }

    private func attemptStartPictureInPicture(remainingAttempts: Int) {
        guard let pictureInPictureController,
              !pictureInPictureController.isPictureInPictureActive else {
            return
        }

        guard remainingAttempts > 0 else {
            debugPrint("PiP did not become possible before attempts were exhausted")
            return
        }

        guard pictureInPictureController.isPictureInPicturePossible else {
            debugPrint("PiP not yet possible; retrying")
            let workItem = DispatchWorkItem { [weak self] in
                self?.attemptStartPictureInPicture(remainingAttempts: remainingAttempts - 1)
            }
            startAttemptWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
            return
        }

        activateAudioSession()
        pictureInPictureController.startPictureInPicture()
    }

    private func cancelPendingStart() {
        startAttemptWorkItem = nil
    }
    
    private func activateAudioSession() {
        changeAudioSession(activate: true)
    }

    private func deactivateAudioSession() {
        changeAudioSession(activate: false)
    }
    
    // TODO: add support of audio streaming...
    private func changeAudioSession(activate: Bool) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            if activate {
                try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers]) // works with the sound turned of because sound is not transferred.
            }
            try audioSession.setActive(activate, options: [.notifyOthersOnDeactivation])
        } catch {
            debugPrint("PiP audio session activation failed: \(error.localizedDescription)")
        }
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        if !isStreaming {
            deactivateAudioSession()
        }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        cancelPendingStart()
        debugPrint("PiP started successfully")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        debugPrint("PiP failed to start: \(error.localizedDescription)")
    }
}
