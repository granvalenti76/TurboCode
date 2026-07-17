import SwiftUI
import MarkdownUI

// MARK: - TurboCode Design Tokens

/// A semantic type scale based on SF Pro and SF Mono.
enum AppTypography {
    static let chatForeground = Color.primary.opacity(0.84)
    static let sidebarHeader = Font.system(size: 17, weight: .semibold)
    static let sidebarLabel = Font.system(size: 14)
    static let sidebarTitle = Font.system(size: 14)
    static let sidebarMetadata = Font.system(size: 12)
    static let sectionLabel = Font.system(size: 11, weight: .semibold)
    static let emptyStateTitle = Font.system(size: 24, weight: .semibold)
    static let emptyStateSubtitle = Font.system(size: 14)
    static let control = Font.system(size: 13)
    static let controlEmphasized = Font.system(size: 13, weight: .medium)
    static let metadata = Font.system(size: 11)
    static let badge = Font.system(size: 11, weight: .medium)
    static let code = Font.system(size: 12, design: .monospaced)

    static func chatBody(size: CGFloat) -> Font {
        .system(size: size, weight: .regular)
    }

    static func chatMarkdownTheme(size: CGFloat) -> Theme {
        Theme()
            .text {
                FontFamily(.system(.default))
                FontSize(size)
                ForegroundColor(chatForeground)
            }
            .strong {
                FontWeight(.semibold)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                BackgroundColor(Color.primary.opacity(0.06))
            }
            .heading1 { configuration in
                chatHeading(configuration.label, size: 1.5, top: 22, bottom: 12)
            }
            .heading2 { configuration in
                chatHeading(configuration.label, size: 1.3, top: 20, bottom: 10)
            }
            .heading3 { configuration in
                chatHeading(configuration.label, size: 1.15, top: 18, bottom: 8)
            }
            .heading4 { configuration in
                chatHeading(configuration.label, size: 1, top: 16, bottom: 8)
            }
            .heading5 { configuration in
                chatHeading(configuration.label, size: 0.95, top: 14, bottom: 8)
            }
            .heading6 { configuration in
                chatHeading(configuration.label, size: 0.9, top: 14, bottom: 8)
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.28))
                    .markdownMargin(top: 0, bottom: 14)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.35))
                        .relativeFrame(width: .em(0.16))
                    configuration.label
                        .markdownTextStyle { ForegroundColor(.secondary) }
                        .relativePadding(.leading, length: .em(0.8))
                }
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 2, bottom: 14)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.24))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.88))
                            BackgroundColor(nil)
                        }
                        .padding(14)
                }
                .background(Color.primary.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .markdownMargin(top: 2, bottom: 16)
            }
            .listItem { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.28))
                    .markdownMargin(top: .em(0.18))
            }
    }

    private static func chatHeading<Label: View>(
        _ label: Label,
        size: CGFloat,
        top: CGFloat,
        bottom: CGFloat
    ) -> some View {
        label
            .relativeLineSpacing(.em(0.16))
            .markdownMargin(top: top, bottom: bottom)
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(.em(size))
            }
    }
}

private struct ChatFontSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = 17
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
