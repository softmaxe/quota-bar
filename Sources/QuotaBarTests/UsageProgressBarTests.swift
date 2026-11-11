@testable import QuotaBarApp
import SwiftUI

enum UsageProgressBarTests {
    static func run() {
        for fromEmpty in [false, true] {
            var values: [Double] = []
            var animations: [Bool] = []
            var scheduled: [() -> Void] = []
            UsageProgressBar.moveFill(to: 75, fromEmpty: fromEmpty, reduceMotion: true, update: { value, animation in
                values.append(value)
                animations.append(animation != nil)
            }, schedule: { scheduled.append($0) })
            Harness.expectEqual(values, [75], "Reduce Motion presents the final fill immediately, rollover=\(fromEmpty)")
            Harness.expectEqual(animations, [false], "Reduce Motion disables fill interpolation, rollover=\(fromEmpty)")
            Harness.expect(scheduled.isEmpty, "Reduce Motion never queues an empty-to-full sweep")
        }
        var values: [Double] = []
        var animations: [Bool] = []
        var queued: (() -> Void)?
        UsageProgressBar.moveFill(to: 75, fromEmpty: true, reduceMotion: false, update: { value, animation in
            values.append(value)
            animations.append(animation != nil)
        }, schedule: { queued = $0 })
        Harness.expectEqual(values, [0], "normal rollover first presents an empty fill")
        queued?()
        Harness.expectEqual(values, [0, 75], "normal rollover queues the target after empty reaches the renderer")
        Harness.expectEqual(animations, [false, true], "normal rollover animates only the target")
    }
}
