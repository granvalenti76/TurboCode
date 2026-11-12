import SwiftUI

/// Surface for transient panels stacked above the composer, such as the
/// steering queue and the turn-status answer.
///
/// These panels belong to the composer, so they repeat its surface exactly:
/// the card token, the same continuous corner, hairline and shadow. Using a
/// system control color or a different radius here is what makes a panel
/// read as a separate widget dropped on top of the composer.
struct ComposerShelfModifier: ViewModifier {
    /// Matches the composer card in `InputFieldView`.
    static let cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AppSurface.card,
                in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            .padding(.bottom, 8)
    }
}

extension View {
    func composerShelf() -> some View {
        modifier(ComposerShelfModifier())
    }
}
