import Foundation

// Typed decoding for log lines. `JSONDecoder` skips the fields a scanner does not name instead of
// building a Foundation object for every string in the line, which is most of a transcript line.
// The wrappers below never throw, so a field of an unexpected type reads as absent, exactly as
// the `as?` casts on a `JSONSerialization` dictionary did.

/// A value of the expected type, or nil when the field holds anything else.
struct LooseValue<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        self.value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

/// A JSON scalar as `JSONSerialization` would have bridged it: numbers and booleans become an
/// `NSNumber`, strings stay strings, and everything else is neither.
struct LooseScalar: Decodable {
    /// `NSNumber.intValue` of a number or boolean.
    let number: Int?
    let string: String?

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.singleValueContainer() else {
            self.number = nil
            self.string = nil
            return
        }
        if let value = try? container.decode(Int.self) {
            self.number = value
            self.string = nil
        } else if let value = try? container.decode(Double.self) {
            // `intValue` truncates toward zero. Out-of-range values have no meaningful Int.
            self.number = value.isFinite && abs(value) < 9.2e18 ? Int(value) : 0
            self.string = nil
        } else if let value = try? container.decode(Bool.self) {
            self.number = value ? 1 : 0
            self.string = nil
        } else {
            self.number = nil
            self.string = try? container.decode(String.self)
        }
    }

    /// `JSONNumber.int` of the same field.
    var intValue: Int {
        self.number ?? self.string.flatMap { Int($0) } ?? 0
    }
}

extension Optional where Wrapped == LooseScalar {
    /// `JSONNumber.int` of a field that may be missing.
    var intValue: Int { self?.intValue ?? 0 }
}

extension Optional {
    /// The field's value when present and of the expected type.
    func loose<Value>() -> Value? where Wrapped == LooseValue<Value> {
        self?.value
    }
}

extension JSONDecoder {
    /// Decodes a line in place. The buffer only has to outlive this call.
    func decodeLine<Value: Decodable>(_ type: Value.Type, from line: UnsafeRawBufferPointer) -> Value? {
        guard let base = line.baseAddress, line.count > 0 else { return nil }
        let data = Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
            count: line.count,
            deallocator: .none
        )
        return try? self.decode(type, from: data)
    }
}
