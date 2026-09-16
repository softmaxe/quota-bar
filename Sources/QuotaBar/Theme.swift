import QuotaBarCore
import AppKit
import SwiftUI

/// Per-provider accent colors from CodexBar's default provider descriptors.
enum Theme {
    static func accent(for provider: Provider) -> Color {
        switch provider {
        case .codex: Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
        case .claude: Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)
        }
    }

    static let progressTrack = Color(nsColor: .tertiaryLabelColor).opacity(0.22)
}
