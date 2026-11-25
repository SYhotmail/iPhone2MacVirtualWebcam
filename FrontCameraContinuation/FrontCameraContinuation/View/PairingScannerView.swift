//
//  PairingScannerView.swift
//  FrontCameraContinuation
//

import SwiftUI
import Transport
import Vision
import VisionKit
import os

let pairingLogger = Logger(subsystem: "by.sy.FrontCameraContinuation", category: "pairing")

/// Full-screen QR scanner that reports the first valid Cam2Mac pairing code.
struct PairingScannerView: View {
    let onFound: (PairingInvitation) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if QRScanner.isScannerSupported {
                    QRScanner(onFound: onFound)
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        "Scanner Unavailable",
                        systemImage: "qrcode.viewfinder",
                        description: Text("Scan the code on your Mac with the Camera app instead, then tap the Cam2Mac banner.")
                    )
                }
            }
            .navigationTitle("Scan Mac Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onFound: (PairingInvitation) -> Void
    
    static var isScannerSupported: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        guard !uiViewController.isScanning else { return }
        // Scanning can only start once the scanner is on screen.
        DispatchQueue.main.async {
            do {
                try uiViewController.startScanning()
            } catch {
                pairingLogger.error("QR scanner failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFound: onFound)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onFound: (PairingInvitation) -> Void
        private var didFind = false

        init(onFound: @escaping (PairingInvitation) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !didFind else { return }
            for case let .barcode(barcode) in addedItems {
                guard let value = barcode.payloadStringValue,
                      let url = URL(string: value),
                      let invitation = PairingInvitation(url: url) else {
                    continue
                }
                didFind = true
                pairingLogger.info("Scanned pairing code for \(invitation.serviceName, privacy: .public)")
                onFound(invitation)
                return
            }
        }
    }
}
