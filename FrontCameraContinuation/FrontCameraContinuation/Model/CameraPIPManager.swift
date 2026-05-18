//
//  CameraPIPManager.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 18/05/2026.
//
import Foundation
import AVKit

final class CameraPIPManager: NSObject {
    private var pipController: AVPictureInPictureController!
    let audioSession: AVAudioSession
    
    private var isPossible = false
    private var audioCategoryDefined = false
    private var isPossibleObservation: NSKeyValueObservation? {
        didSet {
            guard let oldValue, oldValue !== isPossibleObservation else {
                return
            }
            oldValue.invalidate()
        }
    }
    
    private var shouldStartPIP = false
    
    init(audioSession: AVAudioSession = .sharedInstance()) {
        self.audioSession = audioSession
        super.init()
    }
    
    static func isPictureInPictureSupported() -> Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }
    
    @discardableResult
    func createPIP(sampleBufferDisplayLayer: AVSampleBufferDisplayLayer) -> Bool {
        guard Self.isPictureInPictureSupported() else {
            pipController = nil
            return false
        }
        
        guard self.pipController?.contentSource?.sampleBufferDisplayLayer !== sampleBufferDisplayLayer else {
            assert(isPossibleObservation != nil)
            return true
        }
        
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: sampleBufferDisplayLayer,
                                                                playbackDelegate: self)
        let pipController = AVPictureInPictureController(contentSource: source)
        pipController.canStartPictureInPictureAutomaticallyFromInline = true
        pipController.requiresLinearPlayback = true
        pipController.setValue(1, forKey: "controlsStyle")
        self.pipController = pipController
        observePIPPossibleState()
        
        do {
            try changeAudioSessionCategory(activate: true)
        } catch {
            debugPrint(error)
            return false
        }
        return true
    }
    
    private func observePIPPossibleState() {
        isPossibleObservation = pipController?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { controller, change in
            let isPossible = change.newValue ?? controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                guard let self, self.isPossibleObservation != nil else {
                    return
                }
                self.isPossible = isPossible
                if self.shouldStartPIP, isPossible {
                    startPIPCore(isPossible: true)
                }
            }
        }
    }
    
    private func startPIPCore(isPossible: Bool) {
        guard isPossible else {
            shouldStartPIP = !pipController.isPictureInPictureActive
            return
        }
        pipController.startPictureInPicture()
    }
    
    private func changeAudioSessionCategory(activate: Bool) throws {
        if activate {
            try audioSession.setCategory(.playAndRecord, mode: .videoChat)
        }
        guard audioCategoryDefined != activate else {
            return
        }
        try audioSession.setActive(activate)
        audioCategoryDefined = activate
    }
    
    func startPIP(sampleBufferDisplayLayer: AVSampleBufferDisplayLayer) {
        guard let pipController else {
            return
        }
        startPIPCore(isPossible: pipController.isPictureInPicturePossible)
    }
    
    func stopPIP(sampleBufferDisplayLayer: AVSampleBufferDisplayLayer) {
        guard self.pipController?.contentSource?.sampleBufferDisplayLayer == sampleBufferDisplayLayer else {
            return
        }
        stopPIP()
    }
    
    func stopPIP() {
        guard let pipController else {
            return
        }
        shouldStartPIP = false
        pipController.stopPictureInPicture()
        self.pipController = nil
        observePIPPossibleState()
        assert(isPossibleObservation == nil)
        try? changeAudioSessionCategory(activate: false)
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension CameraPIPManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // For live content, return a time range with a duration of positiveInfinity.
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {}
}
