import AppKit

nonisolated  enum VideoEffect: Equatable {
    case blur(sigma: Float)
    case backgroundImage

    static let blurMedium = VideoEffect.blur(sigma: 10)
    static let blurMax = VideoEffect.blur(sigma: 20)

    var isBlur: Bool {
        if case .blur = self { return true }
        return false
    }

    var isBackgroundImage: Bool {
        if case .backgroundImage = self { return true }
        return false
    }

    var blurSigma: Float {
        switch self {
        case .blur(let sigma):
            return sigma
        case .backgroundImage:
            return 0
        }
    }
}

enum VideoEffectOption: Int, CaseIterable, Identifiable {
    case blurMedium
    case blurMax
    case backgroundImage

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .blurMedium:
            return "Blur Medium"
        case .blurMax:
            return "Blur Max"
        case .backgroundImage:
            return "Background"
        }
    }

    var effect: VideoEffect {
        switch self {
        case .blurMedium:
            return .blurMedium
        case .blurMax:
            return .blurMax
        case .backgroundImage:
            return .backgroundImage
        }
    }

    init(effect: VideoEffect) {
        switch effect {
        case .blur(let sigma):
            self = sigma >= 15 ? .blurMax : .blurMedium
        case .backgroundImage:
            self = .backgroundImage
        }
    }
}
