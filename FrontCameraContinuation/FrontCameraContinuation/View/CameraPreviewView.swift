import AVFoundation
import Combine
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        defineUIView(view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        defineUIView(uiView)
    }
    
    private func defineUIView(_ uiView: PreviewView) {
        if uiView.session !== session {
            uiView.session = session
            uiView.refreshRotationCoordinator()
        }
    }
    
    static func dismantleUIView(_ uiView: PreviewView, coordinator: ()) {
        uiView.session = nil
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
