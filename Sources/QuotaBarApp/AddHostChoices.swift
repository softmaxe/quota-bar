import QuotaBarCore
import AppKit
import SwiftUI

/// Return and Add must resolve to the highlighted row, including an explicit typed-name choice.
struct AddHostChoices {
    let hosts: [String]
    let typedOption: String?
    private let preferred: String?

    init(query: String, hosts: [String]) {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = hosts.filter {
            RemoteLogMirror.isValidHost($0) && (typed.isEmpty || $0.localizedCaseInsensitiveContains(typed))
        }
        // SSH aliases can differ by case, so only an exact spelling replaces the typed choice.
        self.typedOption = RemoteLogMirror.isValidHost(typed) && !matches.contains(typed) ? typed : nil
        self.hosts = matches + (self.typedOption.map { [$0] } ?? [])
        self.preferred = matches.contains(typed) ? typed : self.hosts.first
    }

    func resolve(selection: String?) -> String? {
        if let selection, self.hosts.contains(selection) { return selection }
        return self.preferred
    }

    func moved(selection: String?, by offset: Int) -> String? {
        guard let current = self.resolve(selection: selection),
              let index = self.hosts.firstIndex(of: current) else { return nil }
        return self.hosts[max(0, min(self.hosts.count - 1, index + offset))]
    }
}

/// Keep ordinary field editing native while routing vertical movement to the suggestions.
struct HostSearchField: NSViewRepresentable {
    @Binding var text: String
    let submit: () -> Void
    let move: (Int) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Search hosts or type devbox"
        field.setAccessibilityLabel("SSH host or alias")
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != self.text { field.stringValue = self.text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: HostSearchField
        init(parent: HostSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            self.parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): self.parent.move(-1)
            case #selector(NSResponder.moveDown(_:)): self.parent.move(1)
            case #selector(NSResponder.insertNewline(_:)): self.parent.submit()
            default: return false
            }
            return true
        }
    }
}
