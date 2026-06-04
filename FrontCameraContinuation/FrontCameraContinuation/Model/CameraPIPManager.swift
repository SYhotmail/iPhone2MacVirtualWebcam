//
//  CameraPIPManager.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 18/05/2026.
//
@preconcurrency import AVFoundation
import AVKit
import Combine

final class CameraPIPManager: NSObject {
    nonisolated
    private enum Constants {
        static let preferredContentSize = CGSize(width: 1080, height: 1920)
        static let startRetries = 8
        static let startRetryDelay: Duration = .milliseconds(150)
    }

    private var pipController: AVPictureInPictureController?
    
    @Cancelling
    private var isPossibleObservation: NSKeyValueObservation?
    @Cancelling
    private var pendingStartTask: Task<Void, Never>?
    
    private weak var sourceView: VideoView?
    private let contentViewController = VideoCallPictureInPictureContentViewController()
    private let previewRendererBridge = SampleBufferRendererBridge(
        queueLabel: "by.sy.FrontCameraContinuation.CameraPIP.render"
    )
    private let audioSession: AVAudioSession
    private var shouldStartWhenPossible = false
    private var frameObservation: AnyCancellable?
    
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
        unbind()
        stopPIP()
        configurePictureInPictureController(for: nil)
    }
    
    private func unbind() {
        previewRendererBridge.unbind()
        frameObservation = nil
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
            unbind()
            return
        }

        previewRendererBridge.bind(frameProvider: frameProvider,
                                   renderer: sampleBufferRenderer)
        observeFrames(frameProvider: frameProvider)
    }

    private func observeFrames(frameProvider: any PreviewDecodedFrameProvidable) {
        frameObservation = frameProvider.decodedFrameSubject()
            .compactMap(Self.preferredContentSize(for:))
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] preferredContentSize in
                self?.preferredContentSize = preferredContentSize
            }
    }
    
    private var preferredContentSize: CGSize {
        get {
            contentViewController.preferredContentSize
        }
        set {
            contentViewController.preferredContentSize = newValue
        }
    }

    nonisolated
    private static func preferredContentSize(for sampleBuffer: CMSampleBuffer) -> CGSize? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }

        let dimensions = CMVideoFormatDescriptionGetPresentationDimensions(
            formatDescription,
            usePixelAspectRatio: true,
            useCleanAperture: true
        )

        guard dimensions.width > 0, dimensions.height > 0 else {
            return nil
        }
        
        return dimensions
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

        preferredContentSize = Constants.preferredContentSize
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
