import QuotaBarCore
import Foundation
import SwiftUI

/// The one line a quota window devotes to its reset, in whichever of its two faces the reader
/// last asked for. Kept out of the view so the wording can be checked without a running menu.
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
            "Resets in \(Formatters.compactDuration(resetsAt.timeIntervalSince(now)))"
        case .clock:
            "Resets \(Formatters.resetClock(resetsAt, now: now, calendar: calendar, locale: locale))"
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
            Text("\(self.text)  ▾")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(self.previewHovered ? Color.primary : Color.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                }
                .fixedSize(horizontal: true, vertical: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .font(.system(size: 11))
        .fixedSize(horizontal: true, vertical: false)
#if DEBUG
        .background {
            QuotaLayoutProbe(identifier: "reset")
        }
#endif
        .accessibilityLabel("Reset time display, \(self.text)")
    }
}
