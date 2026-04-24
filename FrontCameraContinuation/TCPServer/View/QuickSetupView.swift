import SwiftUI

struct QuickSetupView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConnectViewPalette {
        ConnectViewPalette(colorScheme: colorScheme)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: palette.backgroundGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: ConnectViewLayout.sectionSpacing) {
                    VStack(alignment: .leading, spacing: ConnectViewLayout.textStackSpacing) {
                        Text("Quick Setup")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(palette.primaryText)

                        Text("Use this guide when you need a reminder. The main receiver window stays focused on starting the stream and monitoring the feed.")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: ConnectViewLayout.contentSpacing) {
                        checklistRow(
                            number: "1",
                            title: "Move the app to Applications",
                            detail: "System extension installation is most reliable when the host app runs from `/Applications`."
                        )

                        checklistRow(
                            number: "2",
                            title: "Install the virtual camera",
                            detail: "Use the install button in the receiver window, then approve any macOS permission prompt."
                        )

                        checklistRow(
                            number: "3",
                            title: "Start the receiver",
                            detail: "Launch the listener on your Mac before you start streaming from the iPhone."
                        )

                        checklistRow(
                            number: "4",
                            title: "Connect from iPhone",
                            detail: "Enter the Mac IP address and port shown in the receiver window, then tap Start Stream on the phone."
                        )

                        checklistRow(
                            number: "5",
                            title: "Pick the virtual camera in apps",
                            detail: "Choose `Remote Camera` in Zoom, Meet, QuickTime, or another macOS camera app."
                        )
                    }
                }
                .padding(ConnectViewLayout.outerPadding)
            }
        }
        //.frame(minWidth: 560, minHeight: 420)
    }

    private func checklistRow(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: ConnectViewLayout.actionSpacing) {
            Text(number)
                .font(.headline.weight(.bold))
                .foregroundStyle(palette.primaryText)
                .frame(width: ConnectViewLayout.checklistBadgeSize, height: ConnectViewLayout.checklistBadgeSize)
                .background(palette.secondaryPanelBackground, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(palette.primaryText)

                Text(detail)
                    .font(.body)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .padding(ConnectViewLayout.cardPadding)
        .background(palette.panelBackground, in: RoundedRectangle(cornerRadius: ConnectViewLayout.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ConnectViewLayout.cardCornerRadius, style: .continuous)
                .stroke(palette.panelBorder, lineWidth: 1)
        }
    }
}

#Preview {
    QuickSetupView()
}
