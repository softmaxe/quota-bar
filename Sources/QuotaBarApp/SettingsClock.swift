import Combine
import Foundation
import SwiftUI

/// Relative labels need a clock, but advancing them must not reload their underlying data.
@MainActor
final class SettingsClock: ObservableObject {
    @Published private(set) var now: Date
    private let readNow: () -> Date
    private let interval: TimeInterval
    private var timer: Timer?

    var isRunning: Bool { self.timer != nil }

    init(now: @escaping () -> Date = Date.init, interval: TimeInterval = 60) {
        self.readNow = now
        self.interval = interval
        self.now = now()
    }

    func setActive(_ active: Bool) {
        guard active else {
            self.timer?.invalidate()
            self.timer = nil
            return
        }
        guard self.timer == nil else { return }
        // Reopening catches up immediately, even if the next minute tick is still far away.
        self.now = self.readNow()
        let timer = Timer(timeInterval: self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.now = self.readNow()
            }
        }
        timer.tolerance = min(5, self.interval / 10)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { self.timer?.invalidate() }
}

private struct SettingsNowKey: EnvironmentKey {
    static var defaultValue: Date { Date() }
}

extension EnvironmentValues {
    var settingsNow: Date {
        get { self[SettingsNowKey.self] }
        set { self[SettingsNowKey.self] = newValue }
    }
}
