//
//  CameraPIPManager.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 18/05/2026.
//
import AVFoundation
import AVKit
import Combine

@MainActor
final class CameraPIPManager: NSObject {
    private enum Constants {
        static let preferredContentSize = CGSize(width: 1080, height: 1920)
        static let startRetries = 8
        static let startRetryDelay: Duration = .milliseconds(150)
    }

    private var pipController: AVPictureInPictureController?
    private var isPossibleObservation: NSKeyValueObservation? {
        didSet {
            guard let oldValue, oldValue !== isPossibleObservation else {
                return
            }
            oldValue.invalidate()
        }
    }
    private var pendingStartTask: Task<Void, Never>? {
        didSet {
            guard let oldValue else {
                return
            }
            oldValue.cancel()
        }
    }
    private var frameSubscription: AnyCancellable?
    private weak var sourceView: VideoView?
    private let contentViewController = VideoCallPictureInPictureContentViewController()
    private let audioSession: AVAudioSession
    private var shouldStartWhenPossible = false
    
    init(audioSession: AVAudioSession = .sharedInstance()) {
        self.audioSession = audioSession
        super.init()
    }

    static func isPictureInPictureSupported() -> Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    func attach(sourceView: VideoView?, frameProvider: any PreviewDecodedFrameProvidable) {
        bind(frameProvider: frameProvider)

        guard self.sourceView !== sourceView else {
            return
        }

        self.sourceView = sourceView
        configurePictureInPictureController(for: sourceView)
    }

    func detach(sourceView: VideoView) {
        guard self.sourceView === sourceView else {
            return
        }

        self.sourceView = nil
        stopPIP()
        configurePictureInPictureController(for: nil)
    }

    func startPIP() {
        guard isPictureInPictureActive != true else {
            return
        }

        shouldStartWhenPossible = true
        updateAudioSession(isActive: true)
        startPictureInPictureWhenPossible(remainingAttempts: Constants.startRetries)
    }

    func stopPIP() {
        shouldStartWhenPossible = false
        updateAudioSession(isActive: false)
        pipController?.stopPictureInPicture()
    }

    private func bind(frameProvider: any PreviewDecodedFrameProvidable) {
        guard let sampleBufferRenderer = contentViewController.sampleBufferRenderer else {
            frameSubscription = nil
            return
        }
        
        frameSubscription = frameProvider.decodedFrameSubject()
            .onMainAnyPublisher()
            .sink { [weak sampleBufferRenderer] sampleBuffer in
                sampleBufferRenderer?.enqueue(sampleBuffer)
            }
    }
    
    @discardableResult
    private func startPictureInPicture() -> Bool {
        guard let pipController, pipController.isPictureInPicturePossible else {
            return false
        }
        
        if isPictureInPictureActive != true {
            pipController.startPictureInPicture()
        }
        return true
    }
    
    private var isPictureInPictureActive: Bool? {
        pipController?.isPictureInPictureActive
    }

    private func startPictureInPictureWhenPossible(remainingAttempts: Int) {
        guard shouldStartWhenPossible,
              isPictureInPictureActive == false else {
            return
        }

        startPictureInPicture()

        guard remainingAttempts > 0 else {
            return
        }

        pendingStartTask = Task { [weak self] in
            try? await Task.sleep(for: Constants.startRetryDelay)
            guard let self else {
                return
            }
            self.startPictureInPictureWhenPossible(remainingAttempts: remainingAttempts - 1)
        }
    }

    private func configurePictureInPictureController(for sourceView: VideoView?) {
        isPossibleObservation = nil
        pendingStartTask = nil

        guard Self.isPictureInPictureSupported(),
              let sourceView else {
            pipController = nil
            return
        }

        contentViewController.preferredContentSize = Constants.preferredContentSize
        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: contentViewController
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller

        isPossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.shouldStartWhenPossible else {
                    return
                }
                self.startPictureInPicture()
            }
        }
    }

    private func updateAudioSession(isActive: Bool) {
        do {
            if isActive {
                try audioSession.setCategory(
                    .playAndRecord,
                    mode: .videoChat,
                    options: [.mixWithOthers, .defaultToSpeaker]
                )
            }
            try audioSession.setActive(isActive)
        } catch {
            debugPrint("Failed to configure audio session for PiP: \(error)")
        }
    }
}

@MainActor
extension CameraPIPManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        pendingStartTask = nil
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        shouldStartWhenPossible = false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        shouldStartWhenPossible = false
        debugPrint("PiP failed to start: \(error)")
    }
}

private final class VideoCallPictureInPictureContentViewController: AVPictureInPictureVideoCallViewController {
    let videoView = VideoView(frame: .zero)

    override func loadView() {
        view = videoView
    }
    
    var sampleBufferRenderer: AVSampleBufferVideoRenderer? {
        videoView.sampleBufferRenderer
    }
    
    func enqueue(sampleBuffer: CMSampleBuffer) {
        sampleBufferRenderer?.enqueue(sampleBuffer)
    }
}
