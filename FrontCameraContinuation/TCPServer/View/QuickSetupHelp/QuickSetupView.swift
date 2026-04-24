import SwiftUI

struct QuickSetupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = QuickSetupViewModel()

    private var palette: ConnectViewPalette {
        ConnectViewPalette(colorScheme: colorScheme)
    }
    
    private var backgroundGradient: some View {
        LinearGradient(
            colors: palette.backgroundGradient,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private var bodyCore: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading,
                   spacing: ConnectViewLayout.sectionSpacing) {
                VStack(alignment: .leading,
                       spacing: ConnectViewLayout.textStackSpacing) {
                    Text(viewModel.title)
                        .font(.largeTitle.weight(.bold))
                        .fontDesign(.rounded)
                        .foregroundStyle(palette.primaryText)

                    Text(viewModel.subtitle)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVStack(alignment: .leading,
                           spacing: ConnectViewLayout.contentSpacing) {
                    ForEach(viewModel.steps) { step in
                        checklistRow(
                            number: step.number,
                            title: step.title,
                            detail: step.detail
                        )
                    }
                }
            }
            .padding(ConnectViewLayout.outerPadding)
        }
    }

    var body: some View {
        bodyCore.background {
            backgroundGradient
            .ignoresSafeArea()
        }
    }

    private func checklistRow(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top,
               spacing: ConnectViewLayout.actionSpacing) {
            Text(number)
                .font(.headline.weight(.bold))
                .foregroundStyle(palette.primaryText)
                .frame(width: ConnectViewLayout.checklistBadgeSize, height: ConnectViewLayout.checklistBadgeSize)
                .background(palette.secondaryPanelBackground, in: Circle())

            VStack(alignment: .leading,
                   spacing: 4) {
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
