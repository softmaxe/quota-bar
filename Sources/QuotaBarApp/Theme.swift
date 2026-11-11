import QuotaBarCore
import AppKit
import SwiftUI

/// Per-provider accent colors from CodexBar's default provider descriptors.
enum Theme {
    /// Each hue has a deeper variant for light appearances, so bars and marks keep at least 3:1
    /// against a light window, as they do against a dark one.
    static func accent(for provider: Provider) -> Color {
        switch provider {
        case .codex: Self.codexAccent
        case .claude: Self.claudeAccent
        }
    }

    private static let codexAccent = Self.dynamic(light: (38, 133, 148), dark: (73, 163, 176))
    private static let claudeAccent = Self.dynamic(light: (190, 100, 66), dark: (204, 124, 94))

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1)
        })
    }

    /// The chart stub for a day with no bar. It takes the bars' resting and selected opacity.
    static let chartEmptyStub = Color(nsColor: .secondaryLabelColor)

    /// Opaque reference marks stay legible beside bars in either appearance.
    static let chartReference = Self.dynamic(light: (105, 105, 105), dark: (156, 156, 156))

    static let progressTrack = Color(nsColor: .tertiaryLabelColor).opacity(0.22)

    static let cardWellRadius: CGFloat = 7
    static let cardWellFill = Color.primary.opacity(0.06)
    static let cardWellStroke = Color.primary.opacity(0.08)
    static let cardControlRadius: CGFloat = 5
}
