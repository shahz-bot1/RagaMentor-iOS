import SwiftUI

/// Design tokens shared by every studio (PARITY-PLAN §4).
/// Values come from the web suite's studio.css and the shipped app, so
/// native screens match the web by construction. Components grow here
/// milestone by milestone; P0 seeds the tokens.
public enum DesignTokens {
    /// App accent, scheme-adaptive since the design pass (P1.5):
    /// #5b9dff dark, #2f6fe4 light (the web accent per theme).
    public static var accent: Color { Studio.accent }
    /// Default loop-group colour (#5b9dff).
    public static let defaultGroupColorHex = "#5b9dff"
    /// Group colour palette from the web app.
    public static let groupPaletteHex = ["#2dd4bf", "#fbbf24", "#a78bfa", "#fb7185", "#38bdf8"]
}
