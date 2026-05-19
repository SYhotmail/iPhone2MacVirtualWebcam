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
            resetPIPController()
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
        pipController.requiresLinearPlayback = false
        if pipController.value(forKey: "controlsStyle") != nil {
            pipController.setValue(1, forKey: "controlsStyle") // hide play controls..
        }
        pipController.delegate = self
        self.pipController = pipController
        observePIPPossibleState()
        
        try? changeAudioSessionCategory(activate: true)
        
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
        let isPictureInPictureNotActive = !pipController.isPictureInPictureActive
        guard isPossible else {
            self.shouldStartPIP = isPictureInPictureNotActive
            return
        }
        if isPictureInPictureNotActive {
            pipController.startPictureInPicture()
        }
    }
    
    private func changeAudioSessionCategory(activate: Bool) throws {
        guard audioCategoryDefined != activate else {
            return
        }
        debugPrint("Was active \(audioSession.category.rawValue) mode \(audioSession.mode.rawValue)")
        if activate {
            // TODO: 
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        }
        try audioSession.setActive(activate)
        audioCategoryDefined = activate
    }
    
    func startPIP() {
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
    
    private func resetPIPController() {
        pipController = nil
        observePIPPossibleState()
    }
    
    func stopPIP() {
        guard let pipController else {
            return
        }
        shouldStartPIP = false
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        }
        resetPIPController()
        assert(isPossibleObservation == nil)
        // without calling set category
        audioCategoryDefined = false
        try? changeAudioSessionCategory(activate: false)
    }
}

// MARK: - AVPictureInPictureControllerDelegate
extension CameraPIPManager: AVPictureInPictureControllerDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {
        debugPrint("!!! Error \(error)")
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate
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
