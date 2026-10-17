import SwiftUI

/// Design tokens shared by every studio (PARITY-PLAN §4).
/// Values come from the web suite's studio.css and the shipped app, so
/// native screens match the web by construction. Components grow here
/// milestone by milestone; P0 seeds the tokens.
public enum DesignTokens {
    /// App accent (#2f6fe4, matches the AccentColor asset).
    public static let accent = Color(red: 0.184, green: 0.435, blue: 0.894)
    /// Default loop-group colour (#5b9dff).
    public static let defaultGroupColorHex = "#5b9dff"
    /// Group colour palette from the web app.
    public static let groupPaletteHex = ["#2dd4bf", "#fbbf24", "#a78bfa", "#fb7185", "#38bdf8"]
}
