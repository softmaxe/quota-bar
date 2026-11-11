@testable import QuotaBarApp
import AppKit
import SwiftUI

@MainActor
enum AddHostChoicesTests {
    static func run() {
        let hosts = ["build-server", "build", "build-backup"]
        let partial = AddHostChoices(query: "buil", hosts: hosts)
        Harness.expectEqual(partial.resolve(selection: nil), "build-server", "partial input selects its first match")
        Harness.expectEqual(partial.moved(selection: nil, by: 1), "build", "down moves through matching hosts")
        Harness.expectEqual(partial.resolve(selection: "buil"), "buil", "a matching prefix can still be added literally")
        Harness.expectEqual(partial.moved(selection: "buil", by: 1), "buil", "down stops at the last option")
        Harness.expectEqual(partial.moved(selection: nil, by: -1), "build-server", "up stops at the first option")
        Harness.expectEqual(AddHostChoices(query: " build ", hosts: hosts).resolve(selection: nil), "build",
                            "an exact host wins over an earlier partial match")
        Harness.expectEqual(AddHostChoices(query: "new-host", hosts: hosts).resolve(selection: nil), "new-host",
                            "a host outside SSH config remains addable")
        Harness.expectEqual(AddHostChoices(query: "BUILD", hosts: hosts).typedOption, "BUILD",
                            "case-insensitive suggestions preserve an explicitly typed alias")
        Harness.expectEqual(AddHostChoices(query: "bad host", hosts: hosts).resolve(selection: nil), nil,
                            "invalid host input cannot be submitted")
        Harness.expectEqual(AddHostChoices(query: "", hosts: []).resolve(selection: nil), nil, "empty choices cannot submit")
        Harness.expectEqual(partial.resolve(selection: "removed-host"), "build-server", "stale selection falls back to a match")

        var movement = 0
        var submissions = 0
        let field = HostSearchField(text: .constant("build"), submit: { submissions += 1 }, move: { movement += $0 })
        let coordinator = field.makeCoordinator()
        let control = NSTextField()
        let editor = NSTextView()
        Harness.expect(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))),
                       "native field editor routes down to host selection")
        Harness.expectEqual(movement, 1, "down advances one choice")
        Harness.expect(coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))),
                       "native Return uses the same submission as Add")
        Harness.expectEqual(submissions, 1, "Return submits once")
        Harness.expect(!coordinator.control(control, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))),
                       "ordinary cursor editing stays with AppKit")
    }
}
