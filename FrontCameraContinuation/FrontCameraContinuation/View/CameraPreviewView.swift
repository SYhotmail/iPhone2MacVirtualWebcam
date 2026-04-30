import AVFoundation
import Combine
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspect
        defineUIView(view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.defineView(uiView)
        defineUIView(uiView)
    }
    
    private func defineUIView(_ uiView: PreviewView) {
        if uiView.session !== session {
            uiView.session = session
            uiView.refreshRotationCoordinator()
        }
    }
    
    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        uiView.reset()
        coordinator.undefineView(uiView)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    final class Coordinator: NSObject {
        
        lazy var doubleTapGesture: UITapGestureRecognizer! = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(sender: )))
            tap.numberOfTapsRequired = 2
            return tap
        }()
        
        func defineView(_ uiView: PreviewView) {
            uiView.addGestureRecognizer(doubleTapGesture)
        }
        
        func undefineView(_ uiView: PreviewView) {
            guard let index = uiView.gestureRecognizers?.firstIndex(where: { $0 === doubleTapGesture } ) else {
                return
            }
            uiView.gestureRecognizers?.remove(at: index)
        }
        
        @objc private func handleDoubleTap(sender: UITapGestureRecognizer) {
            guard let view = sender.view as? PreviewView else {
                return
            }
            
            switch view.previewLayer.videoGravity {
            case .resizeAspect:
                view.previewLayer.videoGravity = .resizeAspectFill
            case .resizeAspectFill:
                view.previewLayer.videoGravity = .resizeAspect
            default:
                break
            }
        }
        
    }
}

final class PreviewView: UIView {
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationCancellable: AnyCancellable?

    // Use a capture video preview layer as the view's backing layer.
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }
    
    var previewLayer: AVCaptureVideoPreviewLayer! {
        layer as? AVCaptureVideoPreviewLayer
    }
    
    // Connect the layer to a capture session.
    var session: AVCaptureSession? {
        get { previewLayer.session }
        set {
            previewLayer.session = newValue
        }
    }
    
    func reset() {
        rotationCoordinator = nil
        session = nil
    }

    func refreshRotationCoordinator() {
        
        let currentDevice = session?.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first?
            .device
        let currentDeviceID = currentDevice?.uniqueID
        
        guard currentDeviceID != rotationCoordinator?.device?.uniqueID || rotationCoordinator?.previewLayer !== previewLayer else {
            return
        }

        rotationCancellable = nil
        
        rotationCoordinator = currentDevice.flatMap {
            AVCaptureDevice.RotationCoordinator(device: $0, previewLayer: previewLayer)
        }
        
        let queue = DispatchQueue.main
        
        let block: () -> Void = { [weak self] in
            self?.applyPreviewRotation()
        }
        
        block()
        
        rotationCancellable = rotationCoordinator?
            .publisher(for: \.videoRotationAngleForHorizonLevelPreview)
            .receive(on: queue)
            .map { _ in () }
            .sink(receiveValue: block)
    }

    private func applyPreviewRotation() {
        guard let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview,
              let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(angle),
              connection.videoRotationAngle != angle else {
            return
        }
        debugPrint("!!! Apply rotation \(angle) preview")
        connection.videoRotationAngle = angle
    }
}
