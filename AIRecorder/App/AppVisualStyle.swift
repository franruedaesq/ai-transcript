import SwiftUI

enum AppVisualStyle {
    static let pageHorizontalPadding: CGFloat = 20
    static let cardPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 14
    static let cardSpacing: CGFloat = 10
    static let cardCornerRadius: CGFloat = 17
    static let insetCornerRadius: CGFloat = 10

    static let screenTitle = Font.title.bold()
    static let cardTitle = Font.subheadline.weight(.semibold)
    static let sectionTitle = Font.caption.weight(.bold)

    static let mutedText = Color(red: 0.53, green: 0.62, blue: 0.74)
    static let screenBackground = Color.secondary.opacity(0.055)
    static let cardBorder = Color.secondary.opacity(0.14)
    static let insetBackground = Color.secondary.opacity(0.05)
}

private struct AppCardSurfaceModifier: ViewModifier {
    let isSelected: Bool
    let selectedColor: Color

    func body(content: Content) -> some View {
        content
            .background(
                .background,
                in: RoundedRectangle(
                    cornerRadius: AppVisualStyle.cardCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: AppVisualStyle.cardCornerRadius,
                    style: .continuous
                )
                .stroke(
                    isSelected ? selectedColor : AppVisualStyle.cardBorder,
                    lineWidth: isSelected ? 2 : 1
                )
            }
    }
}

private struct AppInsetSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                AppVisualStyle.insetBackground,
                in: RoundedRectangle(
                    cornerRadius: AppVisualStyle.cardCornerRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: AppVisualStyle.cardCornerRadius,
                    style: .continuous
                )
                .stroke(AppVisualStyle.cardBorder.opacity(0.65), lineWidth: 1)
            }
    }
}

extension View {
    func appCardSurface(
        isSelected: Bool = false,
        selectedColor: Color = .accentColor
    ) -> some View {
        modifier(AppCardSurfaceModifier(isSelected: isSelected, selectedColor: selectedColor))
    }

    func appInsetSurface() -> some View {
        modifier(AppInsetSurfaceModifier())
    }
}
