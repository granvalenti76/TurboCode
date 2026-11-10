import AppKit
import SwiftUI

// MARK: - TurboCode Surface Tokens

/// The neutral surfaces of the visual language: a near-white canvas, white
/// cards resting on it, and a slightly darker sidebar.
///
/// Separation comes from these luminance steps rather than from heavy lines,
/// so the order must hold in both appearances: `sidebar` is darker than
/// `canvas`, and `canvas` is darker than `card`. Borders deliberately stay on
/// the system `.separator` style, which already adapts to Increase Contrast.
///
/// These are fixed sRGB values, not system colors: unlike
/// `windowBackgroundColor`, they do not pick up the desktop tint in dark
/// appearance. Dense working surfaces (inspector, diffs, terminal, sheets)
/// still use system colors and are outside this token set for now.
nonisolated enum AppSurface {
    /// One surface as a pair of 24-bit sRGB values, kept as plain numbers so
    /// the luminance order can be verified without resolving a `Color`.
    struct Token: Sendable, Equatable {
        let name: String
        let light: UInt32
        let dark: UInt32

        /// Resolves per appearance, so views update when the theme changes.
        var color: Color {
            let light = light
            let dark = dark
            return Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                return AppSurface.nsColor(hex: isDark ? dark : light)
            })
        }
    }

    /// Background of the main area behind the conversation and pages.
    static let canvasToken = Token(name: "AppSurfaceCanvas", light: 0xFAFAFA, dark: 0x1E1E1E)
    /// Composer, tiles, and cards that rest on the canvas.
    static let cardToken = Token(name: "AppSurfaceCard", light: 0xFFFFFF, dark: 0x282828)
    /// The sidebar column when the user chooses the solid backdrop.
    static let sidebarToken = Token(name: "AppSurfaceSidebar", light: 0xF2F2F2, dark: 0x181818)

    static let allTokens = [canvasToken, cardToken, sidebarToken]

    static let canvas = canvasToken.color
    static let card = cardToken.color
    static let sidebar = sidebarToken.color

    /// Corner radius shared by tiles and cards.
    static let cardCornerRadius: CGFloat = 12

    /// Relative luminance (WCAG) of a 24-bit sRGB value, used to check the
    /// surface order.
    static func luminance(hex: UInt32) -> Double {
        func linear(_ channel: UInt32) -> Double {
            let value = Double(channel) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear((hex >> 16) & 0xFF)
            + 0.7152 * linear((hex >> 8) & 0xFF)
            + 0.0722 * linear(hex & 0xFF)
    }

    private static func nsColor(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
