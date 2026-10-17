import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The web design language as data (PARITY-PLAN §10): studio.css
/// tokens for both themes. Pure values, so tests can pin them.
public struct StudioPalette: Equatable, Sendable {
    public let bg, panel, panel2, text, muted, border, accent: String

    public static let dark = StudioPalette(
        bg: "#101318", panel: "#171c24", panel2: "#1f2631",
        text: "#e8ecf2", muted: "#9aa4b2", border: "#2a323e",
        accent: "#5b9dff")
    public static let light = StudioPalette(
        bg: "#f4f6f9", panel: "#ffffff", panel2: "#eef1f5",
        text: "#1b2330", muted: "#5d6b7d", border: "#dde3ea",
        accent: "#2f6fe4")
}

/// Scheme-adaptive studio colours. Each colour resolves at render
/// time from the active colour scheme (the app sets the scheme from
/// the theme setting, default dark — so these resolve to the dark
/// tokens unless the user picks Light in Settings).
public enum Studio {
    public static var bg: Color { adaptive(\.bg) }
    public static var panel: Color { adaptive(\.panel) }
    public static var panel2: Color { adaptive(\.panel2) }
    public static var text: Color { adaptive(\.text) }
    public static var muted: Color { adaptive(\.muted) }
    public static var border: Color { adaptive(\.border) }
    public static var accent: Color { adaptive(\.accent) }
    /// The accent at web "accent-soft" strength (16% dark, 12% light).
    public static var accentSoft: Color { accent.opacity(0.16) }

    private static func adaptive(_ keyPath: KeyPath<StudioPalette, String>) -> Color {
        color(dark: StudioPalette.dark[keyPath: keyPath],
              light: StudioPalette.light[keyPath: keyPath])
    }

    public static func color(dark darkHex: String, light lightHex: String) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { traits in
            uiColor(hex: traits.userInterfaceStyle == .dark ? darkHex : lightHex)
        })
        #else
        return hex(lightHex)
        #endif
    }

    public static func hex(_ hex: String) -> Color {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        return Color(red: Double((value >> 16) & 0xff) / 255,
                     green: Double((value >> 8) & 0xff) / 255,
                     blue: Double(value & 0xff) / 255)
    }

    #if canImport(UIKit)
    private static func uiColor(hex: String) -> UIColor {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        return UIColor(red: CGFloat((value >> 16) & 0xff) / 255,
                       green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
    #endif
}
