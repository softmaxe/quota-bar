import CQuotaBarRust

/// Reads structural JSON fields through the borrowed, allocation-free Rust prefix filter.
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

    package static func topLevelType(in buffer: UnsafeRawBufferPointer) -> TopLevelType? {
        switch qb_classify_top_level(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count) {
        case 0: return nil
        case 2: return .other
        case 3: return .assistant
        case 4: return .eventMessage
        case 5: return .turnContext
        default: return .indeterminate
        }
    }

    package static func payloadType(in buffer: UnsafeRawBufferPointer) -> PayloadType? {
        switch qb_classify_payload(buffer.baseAddress?.assumingMemoryBound(to: UInt8.self), buffer.count) {
        case 0: return nil
        case 2: return .other
        case 3: return .threadSettingsApplied
        case 4: return .tokenCount
        default: return .indeterminate
        }
    }
}
