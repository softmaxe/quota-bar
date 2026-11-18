//! Allocation-free structural classifier, deliberately matching the Swift prefix filter.
//! This is not a JSON validator: escaped keys/target values remain indeterminate, and
//! classification stops at the first matching key without validating trailing input.

use crate::find_byte;
use std::ops::Range;

const MISSING: i32 = 0;
const INDETERMINATE: i32 = 1;
const OTHER: i32 = 2;

struct ParsedString {
    range: Range<usize>,
    has_escape: bool,
}

enum Lookup<T> {
    Found(T),
    Indeterminate,
    Missing,
}

fn skip_whitespace(bytes: &[u8], index: &mut usize) {
    while matches!(bytes.get(*index), Some(b' ' | b'\t' | b'\r' | b'\n')) {
        *index += 1;
    }
}

fn string_range(bytes: &[u8], index: &mut usize) -> Option<ParsedString> {
    if bytes.get(*index) != Some(&b'"') {
        return None;
    }
    *index += 1;
    let start = *index;
    // Most structural keys and type values fit in this prefix. Avoid two libc calls
    // for those tiny strings while retaining bounded bulk searches for long content.
    let prefix_end = (start + 16).min(bytes.len());
    while *index < prefix_end {
        match bytes[*index] {
            b'"' => {
                let range = start..*index;
                *index += 1;
                return Some(ParsedString {
                    range,
                    has_escape: false,
                });
            }
            b'\\' => return escaped_string_range(bytes, index, start),
            _ => *index += 1,
        }
    }
    let end = *index + find_byte(&bytes[*index..], b'"')?;
    let Some(escape) = find_byte(&bytes[*index..end], b'\\') else {
        *index = end + 1;
        return Some(ParsedString {
            range: start..end,
            has_escape: false,
        });
    };
    *index += escape;
    escaped_string_range(bytes, index, start)
}

fn escaped_string_range(bytes: &[u8], index: &mut usize, start: usize) -> Option<ParsedString> {
    // Avoid a libc call per escape in dense strings. Each backslash consumes exactly
    // one following byte, including quotes and backslashes, as in the Swift filter.
    while let Some(&byte) = bytes.get(*index) {
        if byte == b'\\' {
            *index += 2;
            continue;
        } else if byte == b'"' {
            let range = start..*index;
            *index += 1;
            return Some(ParsedString {
                range,
                has_escape: true,
            });
        }
        *index += 1;
    }
    None
}

fn skip_value(bytes: &[u8], index: &mut usize) -> bool {
    match bytes.get(*index) {
        None => false,
        Some(b'"') => string_range(bytes, index).is_some(),
        Some(b'{' | b'[') => {
            let mut depth = 0usize;
            while let Some(&byte) = bytes.get(*index) {
                match byte {
                    b'"' => {
                        if string_range(bytes, index).is_none() {
                            return false;
                        }
                        continue;
                    }
                    b'{' | b'[' => depth += 1,
                    b'}' | b']' => {
                        depth -= 1;
                        *index += 1;
                        if depth == 0 {
                            return true;
                        }
                        continue;
                    }
                    _ => {}
                }
                *index += 1;
            }
            false
        }
        Some(_) => {
            while let Some(&byte) = bytes.get(*index) {
                if matches!(byte, b',' | b'}' | b']' | b' ' | b'\t' | b'\r' | b'\n') {
                    return true;
                }
                *index += 1;
            }
            true
        }
    }
}

#[inline]
fn value_start(bytes: &[u8], key: &[u8], object_start: usize) -> Lookup<usize> {
    let mut index = object_start;
    skip_whitespace(bytes, &mut index);
    if bytes.get(index) != Some(&b'{') {
        return Lookup::Indeterminate;
    }
    index += 1;
    while index < bytes.len() {
        skip_whitespace(bytes, &mut index);
        if bytes.get(index) == Some(&b'}') {
            return Lookup::Missing;
        }
        let Some(candidate) = string_range(bytes, &mut index) else {
            return Lookup::Indeterminate;
        };
        if candidate.has_escape {
            return Lookup::Indeterminate;
        }
        skip_whitespace(bytes, &mut index);
        if bytes.get(index) != Some(&b':') {
            return Lookup::Indeterminate;
        }
        index += 1;
        skip_whitespace(bytes, &mut index);
        if bytes[candidate.range] == *key {
            return Lookup::Found(index);
        }
        if !skip_value(bytes, &mut index) {
            return Lookup::Indeterminate;
        }
        skip_whitespace(bytes, &mut index);
        match bytes.get(index) {
            Some(b',') => index += 1,
            Some(b'}') => return Lookup::Missing,
            _ => return Lookup::Indeterminate,
        }
    }
    Lookup::Indeterminate
}

#[inline]
fn string_value(bytes: &[u8], object_start: usize) -> Lookup<ParsedString> {
    let mut index = match value_start(bytes, b"type", object_start) {
        Lookup::Found(index) => index,
        Lookup::Indeterminate => return Lookup::Indeterminate,
        Lookup::Missing => return Lookup::Missing,
    };
    match string_range(bytes, &mut index) {
        Some(value) if !value.has_escape => Lookup::Found(value),
        _ => Lookup::Indeterminate,
    }
}

fn classify_top_level(bytes: &[u8]) -> i32 {
    match string_value(bytes, 0) {
        Lookup::Missing => MISSING,
        Lookup::Indeterminate => INDETERMINATE,
        Lookup::Found(value) => match &bytes[value.range] {
            b"assistant" => 3,
            b"event_msg" => 4,
            b"turn_context" => 5,
            _ => OTHER,
        },
    }
}

fn classify_payload(bytes: &[u8]) -> i32 {
    let start = match value_start(bytes, b"payload", 0) {
        Lookup::Found(start) => start,
        Lookup::Indeterminate => return INDETERMINATE,
        Lookup::Missing => return MISSING,
    };
    match string_value(bytes, start) {
        Lookup::Missing => MISSING,
        Lookup::Indeterminate => INDETERMINATE,
        Lookup::Found(value) => match &bytes[value.range] {
            b"thread_settings_applied" => 3,
            b"token_count" => 4,
            _ => OTHER,
        },
    }
}

/// Classifies a borrowed JSONL prefix: 0 missing, 1 indeterminate, 2 other,
/// 3 assistant, 4 event_msg, 5 turn_context. Empty or null input is indeterminate.
///
/// # Safety
/// For nonempty input, `data` must point to `len` readable bytes in one allocation
/// which remains immutable for this call. No pointer is retained.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qb_classify_top_level(data: *const u8, len: usize) -> i32 {
    if data.is_null() || len == 0 || len > isize::MAX as usize {
        return INDETERMINATE;
    }
    // SAFETY: The caller supplies readable borrowed bytes; null and size are checked above.
    classify_top_level(unsafe { std::slice::from_raw_parts(data, len) })
}

/// Classifies payload.type: 0 missing, 1 indeterminate, 2 other,
/// 3 thread_settings_applied, 4 token_count. Empty or null input is indeterminate.
///
/// # Safety
/// For nonempty input, `data` must point to `len` readable bytes in one allocation
/// which remains immutable for this call. No pointer is retained.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qb_classify_payload(data: *const u8, len: usize) -> i32 {
    if data.is_null() || len == 0 || len > isize::MAX as usize {
        return INDETERMINATE;
    }
    // SAFETY: The caller supplies readable borrowed bytes; null and size are checked above.
    classify_payload(unsafe { std::slice::from_raw_parts(data, len) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefix_filter_contract() {
        for (bytes, expected) in [
            (b"".as_slice(), INDETERMINATE),
            (br#"{}"#, MISSING),
            (br#"{"type":"assistant"}"#, 3),
            (br#"{"type":"event_msg"}"#, 4),
            (br#"{"type":"turn_context"}"#, 5),
            (br#"{"type":"user"}"#, OTHER),
            (br#"{"type":"assistant"garbage"#, 3),
            (br#"{"type":"assistant","type":"user"}"#, 3),
            (br#"{"ty\u0070e":"assistant"}"#, INDETERMINATE),
            (br#"{"type":"assi\u0073tant"}"#, INDETERMINATE),
            (br#"{"nested":{"type":"assistant"}}"#, MISSING),
            (br#"{"skip":[{"type":"assistant"}],"type":"user"}"#, OTHER),
            (br#"{"skip":],"type":"assistant"}"#, INDETERMINATE),
            (br#"{"skip":[},"type":"assistant"}"#, 3),
            (br#"{"skip":1,}"#, MISSING),
        ] {
            assert_eq!(classify_top_level(bytes), expected, "{bytes:?}");
        }
    }

    #[test]
    fn payload_contract() {
        for (bytes, expected) in [
            (br#"{}"#.as_slice(), MISSING),
            (br#"{"payload":{}}"#, MISSING),
            (br#"{"payload":null}"#, INDETERMINATE),
            (br#"{"payload":{"type":"token_count"}}"#, 4),
            (br#"{"payload":{"type":"thread_settings_applied"}}"#, 3),
            (br#"{"payload":{"type":"token_count""#, 4),
            (br#"{"payload":{"type":"other"}}"#, OTHER),
            (br#"{"payload":{"type":"token\u005fcount"}}"#, INDETERMINATE),
        ] {
            assert_eq!(classify_payload(bytes), expected, "{bytes:?}");
        }
    }

    #[test]
    fn empty_ffi_input_never_builds_a_null_slice() {
        // SAFETY: Null/empty inputs are explicitly supported and never dereferenced.
        unsafe {
            for len in [0, 1, usize::MAX] {
                assert_eq!(qb_classify_top_level(std::ptr::null(), len), INDETERMINATE);
                assert_eq!(qb_classify_payload(std::ptr::null(), len), INDETERMINATE);
            }
            assert_eq!(qb_classify_top_level(b"x".as_ptr(), 0), INDETERMINATE);
            assert_eq!(
                qb_classify_payload(b"x".as_ptr(), usize::MAX),
                INDETERMINATE
            );
        }
    }

    #[test]
    fn escape_parity_and_large_truncated_strings() {
        for count in 0..128 {
            let mut bytes = br#"{"padding":""#.to_vec();
            bytes.extend(std::iter::repeat_n(b'\\', count));
            bytes.extend_from_slice(br#"","type":"assistant"}"#);
            assert_eq!(
                classify_top_level(&bytes),
                if count % 2 == 0 { 3 } else { INDETERMINATE }
            );
        }
        let mut bytes = br#"{"padding":""#.to_vec();
        bytes.extend(std::iter::repeat_n(b'x', 1_048_576));
        assert_eq!(classify_top_level(&bytes), INDETERMINATE);
        bytes.extend_from_slice(br#"","type":"assistant"}"#);
        assert_eq!(classify_top_level(&bytes), 3);
    }
}
