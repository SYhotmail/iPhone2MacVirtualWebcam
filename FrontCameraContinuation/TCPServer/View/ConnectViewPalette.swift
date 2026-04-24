import SwiftUI

struct ConnectViewPalette {
    let colorScheme: ColorScheme

    var backgroundGradient: [Color] {
        switch colorScheme {
        case .dark:
            return [
                Color(red: 0.05, green: 0.08, blue: 0.12),
                Color(red: 0.07, green: 0.14, blue: 0.19),
                Color(red: 0.10, green: 0.18, blue: 0.24)
            ]
        case .light:
            return [
                Color(red: 0.94, green: 0.97, blue: 0.99),
                Color(red: 0.88, green: 0.93, blue: 0.97),
                Color(red: 0.96, green: 0.98, blue: 1.00)
            ]
        @unknown default:
            return ConnectViewPalette(colorScheme: .light).backgroundGradient
        }
    }

    var panelBackground: Color {
        colorScheme == .dark ? .white.opacity(0.08) : .white.opacity(0.74)
    }

    var panelBorder: Color {
        colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.08)
    }

    var secondaryPanelBackground: Color {
        colorScheme == .dark ? .white.opacity(0.05) : .white.opacity(0.58)
    }

    var primaryText: Color {
        colorScheme == .dark ? .white : Color.black.opacity(0.86)
    }

    var secondaryText: Color {
        colorScheme == .dark ? .white.opacity(0.72) : Color.black.opacity(0.62)
    }

    var accentGradient: [Color] {
        [
            Color(red: 0.16, green: 0.70, blue: 0.84),
            Color(red: 0.21, green: 0.47, blue: 0.93)
        ]
    }

    var activeGradient: [Color] {
        [
            Color(red: 0.16, green: 0.72, blue: 0.50),
            Color(red: 0.08, green: 0.58, blue: 0.37)
        ]
    }

    var destructiveGradient: [Color] {
        [
            Color(red: 0.84, green: 0.29, blue: 0.30),
            Color(red: 0.63, green: 0.16, blue: 0.19)
        ]
    }

    var cautionColor: Color {
        Color(red: 0.92, green: 0.68, blue: 0.17)
    }

    var successColor: Color {
        Color(red: 0.24, green: 0.78, blue: 0.46)
    }
}
