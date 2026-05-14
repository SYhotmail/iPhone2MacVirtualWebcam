import AVFoundation
import AVKit
import Combine
import UIKit

final class CameraPreviewPIPController: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    let isSupported = AVPictureInPictureController.isPictureInPictureSupported()

    private let sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
    private var pictureInPictureController: AVPictureInPictureController?
    private var sampleBufferCancellable: AnyCancellable?
    private var startAttemptWorkItem: DispatchWorkItem? {
        didSet {
            guard let oldValue, oldValue !== startAttemptWorkItem else {
                return
            }
            oldValue.cancel()
        }
    }
    private var isStreamingRequested = false

    override init() {
        super.init()
        configureDisplayLayer()
        rebuildControllerIfNeeded()
    }

    func bindSampleBuffers(_ publisher: AnyPublisher<CMSampleBuffer, Never>) {
        sampleBufferCancellable = publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sampleBuffer in
                self?.enqueue(sampleBuffer)
            }
    }

    func updateStreamingState(_ isStreamingRequested: Bool) {
        guard self.isStreamingRequested != isStreamingRequested else {
            return
        }

        self.isStreamingRequested = isStreamingRequested
        pictureInPictureController?.invalidatePlaybackState()

        guard !isStreamingRequested else {
            return
        }

        startAttemptWorkItem = nil
        if pictureInPictureController?.isPictureInPictureActive == true {
            pictureInPictureController?.stopPictureInPicture()
        }
        flushDisplayLayer()
        deactivateAudioSession()
    }

    func start() {
        guard isStreamingRequested else {
            debugPrint("PiP requires an active or pending stream")
            return
        }

        guard let pictureInPictureController else {
            debugPrint("PiP controller is not ready")
            return
        }

        activateAudioSession()
        startPictureInPictureWhenPossible(with: pictureInPictureController, remainingAttempts: 8)
    }

    func stop() {
        startAttemptWorkItem = nil
        pictureInPictureController?.stopPictureInPicture()
        flushDisplayLayer()
        deactivateAudioSession()
    }

    private func configureDisplayLayer() {
        //sampleBufferDisplayLayer.videoGravity = .resizeAspectFill
        //sampleBufferDisplayLayer.backgroundColor = UIColor.black.cgColor
        //sampleBufferDisplayLayer.isOpaque = true
    }

    private func rebuildControllerIfNeeded() {
        guard isSupported else {
            pictureInPictureController = nil
            return
        }

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferDisplayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = false
        
        pictureInPictureController = controller
    }

    private func startPictureInPictureWhenPossible(
        with pictureInPictureController: AVPictureInPictureController,
        remainingAttempts: Int
    ) {
        guard remainingAttempts > 0 else {
            debugPrint("PiP is not possible in the current context")
            return
        }

        if pictureInPictureController.isPictureInPicturePossible {
            pictureInPictureController.startPictureInPicture()
            return
        }

        debugPrint("PiP not yet possible; retrying")
        let workItem = DispatchWorkItem { [weak self] in
            self?.startPictureInPictureWhenPossible(
                with: pictureInPictureController,
                remainingAttempts: remainingAttempts - 1
            )
        }
        startAttemptWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func enqueue(_ sampleBuffer: CMSampleBuffer) {
        guard isStreamingRequested else {
            return
        }

        if sampleBufferDisplayLayer.status == .failed {
            sampleBufferDisplayLayer.flush()
        }

        sampleBufferDisplayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
    }

    private func flushDisplayLayer() {
        sampleBufferDisplayLayer.flushAndRemoveImage()
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        debugPrint("PiP will start")
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        startAttemptWorkItem = nil
        debugPrint("PiP started")
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        debugPrint("PiP will stop")
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        flushDisplayLayer()
        deactivateAudioSession()
        debugPrint("PiP stopped")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        debugPrint("PiP failed to start: \(error.localizedDescription)")
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // Live camera PiP is always treated as playing while a stream is requested.
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        !isStreamingRequested
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        debugPrint("PiP render size changed to \(newRenderSize.width)x\(newRenderSize.height)")
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    private func activateAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.ambient, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            debugPrint("PiP audio session activation failed: \(error.localizedDescription)")
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            debugPrint("PiP audio session deactivation failed: \(error.localizedDescription)")
        }
    }
}
