import SwiftUI

// MARK: - TurboCode Design Tokens

/// A semantic type scale based on SF Pro and SF Mono.
enum AppTypography {
    static let sidebarLabel = Font.system(size: 15)
    static let sidebarTitle = Font.system(size: 15)
    static let sidebarMetadata = Font.system(size: 12)
    static let sectionLabel = Font.system(size: 13, weight: .semibold)
    static let control = Font.system(size: 13)
    static let controlEmphasized = Font.system(size: 13, weight: .medium)
    static let metadata = Font.system(size: 11)
    static let badge = Font.system(size: 11, weight: .medium)
    static let code = Font.system(size: 12, design: .monospaced)

    static func chatBody(size: CGFloat) -> Font {
        .system(size: size, weight: .regular)
    }
}

private struct ChatFontSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 15
}

extension EnvironmentValues {
    var chatFontSize: CGFloat {
        get { self[ChatFontSizeKey.self] }
        set { self[ChatFontSizeKey.self] = newValue }
    }
}

extension View {
    /// A restrained selection treatment that lets the native sidebar material
    /// remain the dominant surface.
    @ViewBuilder
    func sidebarSelectionBackground(_ isSelected: Bool) -> some View {
        if isSelected {
            self.background(
                Color.primary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        } else {
            self
        }
    }
}
