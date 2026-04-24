import CoreGraphics

enum ConnectViewLayout {
    static let minimumWindowSize = CGSize(width: 900, height: 600)

    static let outerPadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let compactCardPadding: CGFloat = 14
    static let inputPadding: CGFloat = 12
    static let badgeHorizontalPadding: CGFloat = 11
    static let badgeVerticalPadding: CGFloat = 6
    static let checklistBadgeSize: CGFloat = 30

    static let headerCornerRadius: CGFloat = 32
    static let cardCornerRadius: CGFloat = 30
    static let nestedCardCornerRadius: CGFloat = 24
    static let controlCornerRadius: CGFloat = 22
    static let compactControlCornerRadius: CGFloat = 20
    static let previewCornerRadius: CGFloat = 28
    static let infoBannerCornerRadius: CGFloat = 18

    static let headerSpacing: CGFloat = 14
    static let columnSpacing: CGFloat = 14
    static let contentSpacing: CGFloat = 12
    static let textStackSpacing: CGFloat = 6
    static let actionSpacing: CGFloat = 8
    static let emptyStateSpacing: CGFloat = 10

    static let heroOrbSize: CGFloat = 380
    static let heroOrbBlur: CGFloat = 36
    static let heroOrbOffset = CGSize(width: -360, height: -240)

    static let accentOrbSize: CGFloat = 420
    static let accentOrbBlur: CGFloat = 44
    static let accentOrbOffset = CGSize(width: 420, height: 240)

    static let statusCardWidth: CGFloat = 240
    static let sidebarMinWidth: CGFloat = 360
    static let sidebarMaxWidth: CGFloat = 400
    static let previewMinWidth: CGFloat = 460
    static let previewMinHeight: CGFloat = 400
    static let previewMaxHeight: CGFloat = 470
    static let metricCardMinHeight: CGFloat = 90
    static let previewTextMaxWidth: CGFloat = 420
    static let statusCapsuleWidth: CGFloat = 42
    static let statusCapsuleHeight: CGFloat = 6
    private static let sidebarWidthRatio: CGFloat = 0.38
    private static let previewHeightRatio: CGFloat = 0.46

    static func sidebarWidth(for availableWidth: CGFloat) -> CGFloat {
        let proposed = availableWidth * sidebarWidthRatio
        return min(max(proposed, sidebarMinWidth), sidebarMaxWidth)
    }

    static func previewHeight(for availableHeight: CGFloat) -> CGFloat {
        let proposed = availableHeight * previewHeightRatio
        return min(max(proposed, previewMinHeight), previewMaxHeight)
    }
}
