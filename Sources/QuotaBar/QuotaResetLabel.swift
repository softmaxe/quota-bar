import QuotaBarCore
import Foundation
import SwiftUI

/// The one line a quota window devotes to its reset, in whichever of its two faces the reader
/// last asked for. Kept out of the view so the wording can be checked without a running menu.
/// The word "Resets" is left to the view's symbol and accessibility label, which keeps the longest
/// clock face on one line beside the pace summary in a 280pt card.
enum QuotaResetLabel {
    static func text(
        resetsAt: Date,
        mode: QuotaResetDisplayMode,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        switch mode {
        case .countdown:
            // "in" only reads right in front of a duration, which is why the clock face drops it.
            "in \(Formatters.compactDuration(resetsAt.timeIntervalSince(now)))"
        case .clock:
            Formatters.resetClock(resetsAt, now: now, calendar: calendar, locale: locale)
        }
    }
}

/// Both quota windows use the same saved reset-time mode.
struct ResetLabel: View {
    let text: String
    let mode: QuotaResetDisplayMode
    var previewHovered = false
    let onModeChanged: (QuotaResetDisplayMode) -> Void

    var body: some View {
        Menu {
            Button(self.mode == .countdown ? "Show reset date" : "Show countdown") {
                self.onModeChanged(self.mode.toggled)
            }
        } label: {
            // One concatenated Text: the borderless menu flattens its label, and inline images
            // are what survive it, where padding, borders and stacked views do not.
            (
                Text(Image(systemName: "arrow.clockwise"))
                    .font(.system(size: 9, weight: .semibold))
                    + Text(" \(self.text) ")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    + Text(Image(systemName: "chevron.down"))
                    .font(.system(size: 7, weight: .bold))
            )
            .foregroundStyle(self.previewHovered ? Color.primary : Color.secondary)
            .fixedSize(horizontal: true, vertical: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .font(.system(size: 11))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Reset time display, resets \(self.text)")
    }
}
