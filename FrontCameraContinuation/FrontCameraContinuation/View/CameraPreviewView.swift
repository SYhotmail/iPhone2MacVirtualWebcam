import AVFoundation
import Combine
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.session !== session {
            uiView.session = session
        }
        
        uiView.refreshRotationCoordinator()
    }
}

final class PreviewView: UIView {
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationCancellable: AnyCancellable?
    private var rotationDeviceID: String?

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
        
        defer {
            applyPreviewRotation()
        }
        
        let currentDevice = session?.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first?
            .device
        let currentDeviceID = currentDevice?.uniqueID
        
        guard currentDeviceID != rotationDeviceID || rotationCoordinator?.previewLayer !== previewLayer else {
            return
        }

        rotationCancellable = nil
        rotationCoordinator = currentDevice.map {
            AVCaptureDevice.RotationCoordinator(device: $0, previewLayer: previewLayer)
        }
        rotationDeviceID = currentDeviceID
        rotationCancellable = rotationCoordinator?
            .publisher(for: \.videoRotationAngleForHorizonLevelPreview)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyPreviewRotation()
            }
    }

    private func applyPreviewRotation() {
        guard let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview,
              let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(angle),
              connection.videoRotationAngle != angle else {
            return
        }
        connection.videoRotationAngle = angle
    }
}
