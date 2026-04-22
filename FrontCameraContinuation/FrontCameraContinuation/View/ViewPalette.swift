import SwiftUI

struct ViewPalette {
    let colorScheme: ColorScheme

    var backgroundGradient: [Color] {
        switch colorScheme {
        case .dark:
            return [
                Color(red: 0.14, green: 0.19, blue: 0.31),
                Color(red: 0.09, green: 0.17, blue: 0.28),
                Color(red: 0.04, green: 0.08, blue: 0.16)
            ]
        case .light:
            return [
                Color(red: 0.97, green: 0.98, blue: 1.0),
                Color(red: 0.86, green: 0.92, blue: 0.98),
                Color(red: 0.93, green: 0.95, blue: 1.0)
            ]
        @unknown default:
            return ViewPalette(colorScheme: .light).backgroundGradient
        }
    }

    var startActionColors: [Color] {
        [
            Color(red: 0.18, green: 0.68, blue: 0.89),
            Color(red: 0.12, green: 0.42, blue: 0.76)
        ]
    }

    var stopActionColors: [Color] {
        [
            Color(red: 0.87, green: 0.21, blue: 0.28),
            Color(red: 0.60, green: 0.11, blue: 0.16)
        ]
    }

    var primaryText: Color {
        colorScheme == .dark ? .white : Color.black.opacity(0.88)
    }

    var secondaryText: Color {
        colorScheme == .dark ? .white.opacity(0.78) : Color.black.opacity(0.62)
    }

    var cardBackground: Color {
        colorScheme == .dark ? .white.opacity(0.10) : .white.opacity(0.68)
    }

    var cardBorder: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .white.opacity(0.42)
    }

    var fieldBackground: Color {
        colorScheme == .dark ? .white.opacity(0.12) : .white.opacity(0.74)
    }

    var fieldBorder: Color {
        colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.06)
    }
}
