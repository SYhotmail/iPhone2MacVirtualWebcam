enum VideoEffect: Int, CaseIterable {
    case none
    case medium
    case max
}

extension VideoEffect: Identifiable {
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none:
            return "None"
        case .medium:
            return "Medium"
        case .max:
            return "Max"
        }
    }

    nonisolated var blurSigma: Float {
        switch self {
        case .none:
            return 0
        case .medium:
            return 10
        case .max:
            return 20
        }
    }
}
