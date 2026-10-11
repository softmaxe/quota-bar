import Foundation

/// Reads only the structural JSON fields needed to decide whether a JSONL record merits full
/// parsing. It never assumes key order or a maximum prefix length.
package enum JSONLogClassifier {
    package enum TopLevelType: Equatable {
        case assistant
        case eventMessage
        case indeterminate
        case turnContext
        case other
    }

    package enum PayloadType: Equatable {
        case indeterminate
        case threadSettingsApplied
        case tokenCount
        case other
    }

    private struct ParsedString {
        let range: Range<Int>
        let hasEscape: Bool
    }

    private enum Lookup<Value> {
        case found(Value)
        case indeterminate
        case missing
    }

    private static let typeKey = Array("type".utf8)
    private static let payloadKey = Array("payload".utf8)
    private static let assistant = Array("assistant".utf8)
    private static let eventMessage = Array("event_msg".utf8)
    private static let turnContext = Array("turn_context".utf8)
    private static let threadSettingsApplied = Array("thread_settings_applied".utf8)
    private static let tokenCount = Array("token_count".utf8)

    package static func topLevelType(in buffer: UnsafeRawBufferPointer) -> TopLevelType? {
        let value: ParsedString
        switch self.stringValue(for: Self.typeKey, inObjectAt: 0, buffer: buffer) {
        case let .found(found): value = found
        case .indeterminate: return .indeterminate
        case .missing: return nil
        }
        if self.matches(value.range, Self.assistant, buffer: buffer) { return .assistant }
        if self.matches(value.range, Self.eventMessage, buffer: buffer) { return .eventMessage }
        if self.matches(value.range, Self.turnContext, buffer: buffer) { return .turnContext }
        return .other
    }

    package static func payloadType(in buffer: UnsafeRawBufferPointer) -> PayloadType? {
        let payload: Int
        switch self.valueStart(for: Self.payloadKey, inObjectAt: 0, buffer: buffer) {
        case let .found(found): payload = found
        case .indeterminate: return .indeterminate
        case .missing: return nil
        }
        let value: ParsedString
        switch self.stringValue(for: Self.typeKey, inObjectAt: payload, buffer: buffer) {
        case let .found(found): value = found
        case .indeterminate: return .indeterminate
        case .missing: return nil
        }
        if self.matches(value.range, Self.threadSettingsApplied, buffer: buffer) { return .threadSettingsApplied }
        if self.matches(value.range, Self.tokenCount, buffer: buffer) { return .tokenCount }
        return .other
    }

    private static func stringValue(
        for key: [UInt8],
        inObjectAt objectStart: Int,
        buffer: UnsafeRawBufferPointer
    ) -> Lookup<ParsedString> {
        let start: Int
        switch self.valueStart(for: key, inObjectAt: objectStart, buffer: buffer) {
        case let .found(found): start = found
        case .indeterminate: return .indeterminate
        case .missing: return .missing
        }
        var index = start
        guard let value = self.stringRange(at: &index, buffer: buffer) else { return .indeterminate }
        return value.hasEscape ? .indeterminate : .found(value)
    }

    private static func valueStart(
        for key: [UInt8],
        inObjectAt objectStart: Int,
        buffer: UnsafeRawBufferPointer
    ) -> Lookup<Int> {
        var index = objectStart
        self.skipWhitespace(at: &index, buffer: buffer)
        guard index < buffer.count, buffer[index] == UInt8(ascii: "{") else { return .indeterminate }
        index += 1

        while index < buffer.count {
            self.skipWhitespace(at: &index, buffer: buffer)
            if index < buffer.count, buffer[index] == UInt8(ascii: "}") { return .missing }
            guard let candidate = self.stringRange(at: &index, buffer: buffer) else { return .indeterminate }
            if candidate.hasEscape { return .indeterminate }
            self.skipWhitespace(at: &index, buffer: buffer)
            guard index < buffer.count, buffer[index] == UInt8(ascii: ":") else { return .indeterminate }
            index += 1
            self.skipWhitespace(at: &index, buffer: buffer)
            if self.matches(candidate.range, key, buffer: buffer) { return .found(index) }
            guard self.skipValue(at: &index, buffer: buffer) else { return .indeterminate }
            self.skipWhitespace(at: &index, buffer: buffer)
            if index < buffer.count, buffer[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if index < buffer.count, buffer[index] == UInt8(ascii: "}") { return .missing }
            return .indeterminate
        }
        return .indeterminate
    }

    private static func stringRange(
        at index: inout Int,
        buffer: UnsafeRawBufferPointer
    ) -> ParsedString? {
        guard index < buffer.count, buffer[index] == UInt8(ascii: "\"") else { return nil }
        index += 1
        let start = index
        var escaped = false
        var hasEscape = false
        while index < buffer.count {
            let byte = buffer[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if byte == UInt8(ascii: "\\") {
                hasEscape = true
                escaped = true
                index += 1
                continue
            }
            if byte == UInt8(ascii: "\"") {
                let range = start..<index
                index += 1
                return ParsedString(range: range, hasEscape: hasEscape)
            }
            index += 1
        }
        return nil
    }

    private static func skipValue(
        at index: inout Int,
        buffer: UnsafeRawBufferPointer
    ) -> Bool {
        guard index < buffer.count else { return false }
        if buffer[index] == UInt8(ascii: "\"") {
            return self.stringRange(at: &index, buffer: buffer) != nil
        }
        if buffer[index] == UInt8(ascii: "{") || buffer[index] == UInt8(ascii: "[") {
            var depth = 0
            while index < buffer.count {
                let byte = buffer[index]
                if byte == UInt8(ascii: "\"") {
                    guard self.stringRange(at: &index, buffer: buffer) != nil else { return false }
                    continue
                }
                if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") { depth += 1 }
                if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                    depth -= 1
                    index += 1
                    if depth == 0 { return true }
                    continue
                }
                index += 1
            }
            return false
        }
        while index < buffer.count {
            let byte = buffer[index]
            if byte == UInt8(ascii: ",") || byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]")
                || byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
                || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n") {
                return true
            }
            index += 1
        }
        return true
    }

    private static func skipWhitespace(at index: inout Int, buffer: UnsafeRawBufferPointer) {
        while index < buffer.count {
            switch buffer[index] {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n"):
                index += 1
            default:
                return
            }
        }
    }

    private static func matches(
        _ range: Range<Int>,
        _ expected: [UInt8],
        buffer: UnsafeRawBufferPointer
    ) -> Bool {
        guard range.count == expected.count else { return false }
        for offset in expected.indices where buffer[range.lowerBound + offset] != expected[offset] {
            return false
        }
        return true
    }
}
