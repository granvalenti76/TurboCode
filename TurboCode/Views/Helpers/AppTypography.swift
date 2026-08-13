import SwiftUI
import MarkdownUI

// MARK: - TurboCode Design Tokens

/// A semantic type scale based on SF Pro and SF Mono.
enum AppTypography {
    /// Conversation typography follows the native macOS reading scale used by
    /// the reference response: SF Pro, 17 pt, generous Markdown rhythm, and a
    /// softened primary color that remains legible in both appearance modes.
    static let chatDefaultFontSize: CGFloat = 17
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

    /// Complete conversation theme for every Markdown block TurboCode accepts.
    /// Starting from `Theme()` is intentional, but requires styling structural
    /// blocks too; otherwise tables and separators fall back to raw defaults.
    static func chatMarkdownTheme(size: CGFloat) -> Theme {
        Theme()
            .text {
                FontFamily(.system(.default))
                FontSize(size)
                ForegroundColor(chatForeground)
            }
            .strong {
                FontWeight(.medium)
            }
            .link {
                ForegroundColor(.accentColor)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.88))
                ForegroundColor(Color.primary.opacity(0.78))
                // MarkdownUI cannot round an inline text background. Leaving
                // it clear avoids the harsh rectangular chips seen in prose.
                BackgroundColor(nil)
            }
            .heading1 { configuration in
                chatHeading(configuration.label, size: 1.35, top: 24, bottom: 10)
            }
            .heading2 { configuration in
                chatHeading(configuration.label, size: 1.2, top: 22, bottom: 9)
            }
            .heading3 { configuration in
                chatHeading(configuration.label, size: 1.08, top: 20, bottom: 8)
            }
            .heading4 { configuration in
                chatHeading(
                    configuration.label,
                    size: 1,
                    weight: .medium,
                    top: 18,
                    bottom: 7
                )
            }
            .heading5 { configuration in
                chatHeading(
                    configuration.label,
                    size: 0.95,
                    weight: .medium,
                    subdued: true,
                    top: 16,
                    bottom: 7
                )
            }
            .heading6 { configuration in
                chatHeading(
                    configuration.label,
                    size: 0.9,
                    weight: .medium,
                    subdued: true,
                    top: 16,
                    bottom: 7
                )
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.22))
                    .markdownMargin(top: 0, bottom: 12)
            }
            .blockquote { configuration in
                HStack(spacing: 0) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.28))
                        .relativeFrame(width: .em(0.14))
                    configuration.label
                        .markdownTextStyle { ForegroundColor(.secondary) }
                        .relativePadding(.leading, length: .em(0.9))
                }
                .fixedSize(horizontal: false, vertical: true)
                .relativePadding(.vertical, length: .em(0.2))
                .markdownMargin(top: 4, bottom: 14)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.24))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.84))
                            BackgroundColor(nil)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
                }
                .markdownMargin(top: 4, bottom: 16)
            }
            .image { configuration in
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .markdownMargin(top: 8, bottom: 14)
            }
            .list { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownMargin(top: 0, bottom: 12)
            }
            .listItem { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownMargin(top: .em(0.12))
            }
            .bulletedListMarker { configuration in
                Image(systemName: configuration.listLevel == 1 ? "circle.fill" : "circle")
                    .font(.system(size: configuration.listLevel == 1 ? 5.5 : 5))
                    .foregroundStyle(Color.secondary.opacity(0.72))
                    .relativeFrame(minWidth: .em(1.35), alignment: .trailing)
            }
            .numberedListMarker { configuration in
                Text("\(configuration.itemNumber).")
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
                    .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
            }
            .taskListMarker { configuration in
                Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.secondary)
                    .imageScale(.small)
                    .relativeFrame(minWidth: .em(1.45), alignment: .trailing)
            }
            .table { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    // Horizontal rules read like a native data table without
                    // boxing every value in a heavy spreadsheet grid.
                    .markdownTableBorderStyle(
                        .init(
                            .horizontalBorders,
                            color: Color.secondary.opacity(0.24),
                            width: 0.5
                        )
                    )
                    .markdownTableBackgroundStyle(
                        .alternatingRows(
                            Color.clear,
                            Color.primary.opacity(0.025),
                            header: Color.primary.opacity(0.055)
                        )
                    )
                    .markdownMargin(top: 8, bottom: 18)
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 {
                            FontWeight(.medium)
                        }
                        BackgroundColor(nil)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.18))
                    .relativePadding(.horizontal, length: .em(0.7))
                    .relativePadding(.vertical, length: .em(0.48))
            }
            .thematicBreak {
                Divider()
                    .overlay(Color.secondary.opacity(0.2))
                    .markdownMargin(top: 20, bottom: 20)
            }
    }

    private static func chatHeading<Label: View>(
        _ label: Label,
        size: CGFloat,
        weight: Font.Weight = .semibold,
        subdued: Bool = false,
        top: CGFloat,
        bottom: CGFloat
    ) -> some View {
        label
            .relativeLineSpacing(.em(0.16))
            .markdownMargin(top: top, bottom: bottom)
            .markdownTextStyle {
                FontWeight(weight)
                FontSize(.em(size))
                if subdued {
                    ForegroundColor(.secondary)
                }
            }
    }
}

/// Normalizes decorative model output into quieter Markdown for rendering.
/// The stored assistant text remains untouched so copying and transcript replay
/// preserve exactly what the provider returned.
nonisolated enum ChatMarkdownPresentation {
    static func cleaned(_ markdown: String) -> String {
        var activeFence: Character?
        return markdown
            .components(separatedBy: .newlines)
            .map { line in
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                if let delimiter = fenceDelimiter(in: trimmed) {
                    if activeFence == delimiter {
                        activeFence = nil
                    } else if activeFence == nil {
                        activeFence = delimiter
                    }
                    return line
                }
                guard activeFence == nil else { return line }
                return cleanedTaskListLine(cleanedHeadingLine(line))
            }
            .joined(separator: "\n")
    }

    /// Fenced code is opaque: examples may intentionally contain decorative
    /// Markdown and must never be rewritten for presentation.
    private static func fenceDelimiter(in line: Substring) -> Character? {
        guard let first = line.first, first == "`" || first == "~" else {
            return nil
        }
        return line.prefix(while: { $0 == first }).count >= 3 ? first : nil
    }

    private static func cleanedHeadingLine(_ line: String) -> String {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        var remainder = line.dropFirst(indent.count)
        let hashes = remainder.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return line }
        remainder.removeFirst(hashes.count)
        guard remainder.first?.isWhitespace == true else { return line }
        remainder = remainder.drop(while: \Character.isWhitespace)

        var removedDecoration = false
        while let first = remainder.first, isDecorativeEmoji(first) {
            removedDecoration = true
            remainder.removeFirst()
            remainder = remainder.drop(while: \Character.isWhitespace)
        }
        guard removedDecoration, !remainder.isEmpty else { return line }
        return "\(indent)\(hashes) \(remainder)"
    }

    private static func cleanedTaskListLine(_ line: String) -> String {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        var remainder = line.dropFirst(indent.count)
        guard let marker = remainder.first, marker == "-" || marker == "*" || marker == "+" else {
            return line
        }
        remainder.removeFirst()
        guard remainder.first?.isWhitespace == true else { return line }
        remainder = remainder.drop(while: \Character.isWhitespace)
        guard let icon = remainder.first,
              completedIcons.contains(String(icon)) else {
            return line
        }
        remainder.removeFirst()
        remainder = remainder.drop(while: \Character.isWhitespace)
        let suffix = remainder.isEmpty ? "" : " \(remainder)"
        return "\(indent)\(marker) [x]\(suffix)"
    }

    private static func isDecorativeEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || (scalar.properties.isEmoji && scalar.value > 0x7F)
        }
    }

    private static let completedIcons: Set<String> = ["✅", "☑️", "✔️", "✔"]
}

private struct ChatFontSizeKey: EnvironmentKey {
    static let defaultValue: CGFloat = AppTypography.chatDefaultFontSize
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
