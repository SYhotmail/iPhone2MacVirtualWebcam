import SwiftUI

struct ReceiverMenuBarLabelView: View {
    @Bindable var viewModel: ConnectViewModel
    
    var body: some View {
        Image(systemName: viewModel.menuBarSystemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(activeForegroundStyle)
        .padding(.horizontal, connectionReady ? 10 : 0)
        .padding(.vertical, connectionReady ? 4 : 0)
        .background {
            if connectionReady {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.83, blue: 0.24),
                                Color(red: 1.0, green: 0.59, blue: 0.19)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.menuBarStatusText)
    }
    
    private var connectionReady: Bool { viewModel.connectionReady }


    private var activeForegroundStyle: Color {
        connectionReady ? .black.opacity(0.88) : .primary
    }
}
