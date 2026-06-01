import SwiftUI

struct ReceiverMenuBarView: View {
    @Bindable var viewModel: ConnectViewModel
    
    let openWindowAction: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusSection

            Divider()

            networkSection

            Divider()

            controlsSection
        }
        .task {
            await viewModel.refreshNetworkAddresses()
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(viewModel.menuBarStatusText, systemImage: viewModel.menuBarSystemImage)
                .font(.headline)

            Text("Status: \(viewModel.menuBarLabelText)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Receiver Address")
                .font(.subheadline.weight(.semibold))

            Text(viewModel.addressText)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            Button("Copy Address") {
                viewModel.copyConnectionAddress()
            }
        }
    }
    
    private func startServer() {
        viewModel.startServer()
    }
    
    private func stopServer() {
        viewModel.stopServer()
    }

    private var controlsSection: some View {
        Group {
            if viewModel.isRunning {
                Button("Stop Receiver",
                       systemImage: "stop.fill",
                       action: stopServer)
            } else {
                Button("Start Receiver",
                       systemImage: "play.fill",
                       action: startServer)
            }

            Button("Open Receiver Window",
                   systemImage: "macwindow",
                   action: openWindowAction)
        }
    }
}
