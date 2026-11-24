//
//  PairingQRView.swift
//  Cam2Mac
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import Transport

/// Sheet showing the one-time QR code an iPhone scans to pair with this Mac.
struct PairingQRView: View {
    let invitation: PairingInvitation
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair iPhone")
                .font(.title2.weight(.bold))

            if let image = Self.qrImage(for: invitation.url.absoluteString) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Pairing QR code")
            }

            VStack(spacing: 4) {
                Text("In the iPhone app, tap **Pair with Mac** and scan this code.")
                Text("The iPhone must be on the same Wi-Fi as **\(invitation.serviceName)**. The code works once and expires in 5 minutes.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 380)
    }

    private static func qrImage(for string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)) else {
            return nil
        }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

extension PairingInvitation: @retroactive Identifiable {
    public var id: Data { token }
}
