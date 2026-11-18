// Adapted from QuotaBar's ClaudeCodeAdapter, itself adapted from CodexBar
// (MIT, Copyright 2026 Peter Steinberger). See THIRD_PARTY_NOTICES.md.

use serde::de::{MapAccess, Visitor};
use serde::{Deserialize, Deserializer};
use serde_json::Value;
use std::ffi::c_void;
use std::marker::PhantomData;
use std::panic::catch_unwind;
use std::ptr;

const PARSED: u32 = 0;
const IGNORED: u32 = 1;
const FALLBACK: u32 = 2;
const INTERNAL_ERROR: u32 = 3;
const INVALID_ARGUMENT: u32 = 4;

/// Foundation keyed containers reject positional arrays, unlike Serde structs.
struct MapOnly<T>(T);

impl<'de, T: Deserialize<'de>> Deserialize<'de> for MapOnly<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct ObjectVisitor<T>(PhantomData<T>);
        impl<'de, T: Deserialize<'de>> Visitor<'de> for ObjectVisitor<T> {
            type Value = MapOnly<T>;

            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("a JSON object")
            }

            fn visit_map<A: MapAccess<'de>>(self, access: A) -> Result<Self::Value, A::Error> {
                T::deserialize(serde::de::value::MapAccessDeserializer::new(access)).map(MapOnly)
            }
        }
        deserializer.deserialize_map(ObjectVisitor(PhantomData))
    }
}

// Unknown transcript content is skipped. Duplicate known keys and unexpected
// known-field shapes delegate to Foundation rather than changing loose decoding.
#[derive(Default, Deserialize)]
#[serde(default)]
struct Line {
    #[serde(rename = "type")]
    kind: Option<String>,
    timestamp: Option<String>,
    #[serde(rename = "requestId")]
    request_id: Option<String>,
    uuid: Option<String>,
    message: Option<MapOnly<Message>>,
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct Message {
    id: Option<String>,
    model: Option<String>,
    usage: Option<MapOnly<Usage>>,
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct Usage {
    input_tokens: Value,
    output_tokens: Value,
    cache_creation_input_tokens: Value,
    cache_read_input_tokens: Value,
    cache_creation: Option<MapOnly<CacheCreation>>,
    speed: Option<String>,
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct CacheCreation {
    ephemeral_1h_input_tokens: Value,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ByteString {
    ptr: *const u8,
    len: usize,
}

impl ByteString {
    const EMPTY: Self = Self {
        ptr: ptr::null(),
        len: 0,
    };

    fn borrow(value: &str) -> Self {
        Self {
            ptr: value.as_ptr(),
            len: value.len(),
        }
    }
}

/// All views are valid until the unique owner is released by qb_claude_free.
#[repr(C)]
pub struct ClaudeResult {
    status: u32,
    counts: [i64; 5],
    timestamp: ByteString,
    model: ByteString,
    message_id: ByteString,
    request_id: ByteString,
    uuid: ByteString,
    speed: ByteString,
    owner: *mut c_void,
}

impl ClaudeResult {
    fn empty(status: u32) -> Self {
        Self {
            status,
            counts: [0; 5],
            timestamp: ByteString::EMPTY,
            model: ByteString::EMPTY,
            message_id: ByteString::EMPTY,
            request_id: ByteString::EMPTY,
            uuid: ByteString::EMPTY,
            speed: ByteString::EMPTY,
            owner: ptr::null_mut(),
        }
    }
}

struct OwnedRecord {
    timestamp: String,
    model: String,
    message_id: String,
    request_id: String,
    uuid: String,
    speed: String,
}

fn scalar(value: &Value) -> Result<i64, ()> {
    if let Some(integer) = value.as_i64() {
        return Ok(integer);
    }
    if value.is_f64() {
        // Foundation tries exact Int decoding before Double, including decimal and
        // exponent spellings. Delegate all floating encodings, not only values >2^53.
        return Err(());
    }
    if let Some(boolean) = value.as_bool() {
        return Ok(i64::from(boolean));
    }
    Ok(value
        .as_str()
        .and_then(|text| text.parse().ok())
        .unwrap_or(0))
}

fn decode(bytes: &[u8]) -> Result<ClaudeResult, ()> {
    let line = serde_json::from_slice::<MapOnly<Line>>(bytes)
        .map_err(|_| ())?
        .0;
    if line.kind.as_deref() != Some("assistant") {
        return Ok(ClaudeResult::empty(IGNORED));
    }
    let Some(message) = line.message.map(|value| value.0) else {
        return Ok(ClaudeResult::empty(IGNORED));
    };
    let Some(usage) = message.usage.map(|value| value.0) else {
        return Ok(ClaudeResult::empty(IGNORED));
    };
    let (Some(timestamp), Some(model)) = (line.timestamp, message.model) else {
        return Ok(ClaudeResult::empty(IGNORED));
    };
    let write = scalar(&usage.cache_creation_input_tokens)?;
    let write_1h = usage
        .cache_creation
        .as_ref()
        .map(|value| scalar(&value.0.ephemeral_1h_input_tokens))
        .transpose()?
        .unwrap_or(0);
    let counts = [
        scalar(&usage.input_tokens)?,
        scalar(&usage.output_tokens)?,
        write,
        write_1h.min(write),
        scalar(&usage.cache_read_input_tokens)?,
    ];
    let total = [counts[0], counts[1], counts[2], counts[4]]
        .into_iter()
        .try_fold(0_i64, i64::checked_add);
    if counts.iter().any(|count| *count < 0) || !matches!(total, Some(value) if value > 0) {
        return Ok(ClaudeResult::empty(IGNORED));
    }
    let message_id = message.id.unwrap_or_default();
    let request_id = line.request_id.unwrap_or_default();
    let uuid = line.uuid.unwrap_or_default();
    if message_id.is_empty() && request_id.is_empty() && uuid.is_empty() {
        // Foundation canonical JSON hashing is part of the persisted identity format.
        return Err(());
    }
    let owner = Box::new(OwnedRecord {
        timestamp,
        model,
        message_id,
        request_id,
        uuid,
        speed: usage.speed.unwrap_or_default(),
    });
    let result = ClaudeResult {
        status: PARSED,
        counts,
        timestamp: ByteString::borrow(&owner.timestamp),
        model: ByteString::borrow(&owner.model),
        message_id: ByteString::borrow(&owner.message_id),
        request_id: ByteString::borrow(&owner.request_id),
        uuid: ByteString::borrow(&owner.uuid),
        speed: ByteString::borrow(&owner.speed),
        owner: Box::into_raw(owner).cast(),
    };
    Ok(result)
}

fn contain_failure(
    work: impl FnOnce() -> Result<ClaudeResult, ()> + std::panic::UnwindSafe,
) -> ClaudeResult {
    match catch_unwind(work) {
        Ok(Ok(result)) => result,
        Ok(Err(())) => ClaudeResult::empty(FALLBACK),
        Err(_) => ClaudeResult::empty(INTERNAL_ERROR),
    }
}

/// Decode one complete JSON record, including legal JSON whitespace newlines.
///
/// # Safety
/// `bytes` must name `length` readable bytes for this call (or be null for zero).
/// `output` must name writable, aligned storage not overlapping the input. Its
/// previous owner, if any, must already have been released. No input is retained.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qb_claude_decode(
    bytes: *const u8,
    length: usize,
    output: *mut ClaudeResult,
) {
    if output.is_null() {
        return;
    }
    let result = if length > isize::MAX as usize || (bytes.is_null() && length != 0) {
        ClaudeResult::empty(INVALID_ARGUMENT)
    } else {
        let input = if length == 0 {
            &[]
        } else {
            // SAFETY: readable input and lifetime are supplied by the documented caller contract.
            unsafe { std::slice::from_raw_parts(bytes, length) }
        };
        contain_failure(|| decode(input))
    };
    // SAFETY: output storage belongs to the caller and is valid for this call.
    unsafe { output.write(result) };
}

/// Release one result owner. Its record/string views must not be used afterward.
///
/// # Safety
/// `owner` must be null or an unreleased pointer returned by qb_claude_decode.
/// The caller must release it exactly once, with no simultaneous readers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qb_claude_free(owner: *mut c_void) {
    if !owner.is_null() {
        // SAFETY: ownership is transferred back by the documented caller contract.
        drop(unsafe { Box::from_raw(owner.cast::<OwnedRecord>()) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(usage: &str) -> String {
        format!(
            r#"{{"type":"assistant","timestamp":"2026-11-16T00:00:00Z","message":{{"id":"m","model":"claude-test","usage":{usage}}}}}"#
        )
    }

    #[test]
    fn preserves_token_domains_and_ownership() {
        let text = record(
            r#"{"input_tokens":"10","output_tokens":true,"cache_creation_input_tokens":5,"cache_creation":{"ephemeral_1h_input_tokens":9}}"#,
        );
        let result = decode(text.as_bytes()).unwrap();
        assert_eq!(result.status, PARSED);
        assert_eq!(result.counts, [10, 1, 5, 5, 0]);
        // SAFETY: this result uniquely owns a live Rust allocation.
        unsafe { qb_claude_free(result.owner) };
        assert_eq!(
            decode(record(r#"{"input_tokens":-1}"#).as_bytes())
                .unwrap()
                .status,
            IGNORED
        );
        assert_eq!(
            decode(record(r#"{"input_tokens":9223372036854775807,"output_tokens":1}"#).as_bytes())
                .unwrap()
                .status,
            IGNORED
        );
    }

    #[test]
    fn defers_foundation_specific_representations() {
        for usage in [
            r#"{"input_tokens":9007199254740993.0}"#,
            r#"{"input_tokens":1.5}"#,
            r#"{"input_tokens":1,"input_tokens":2}"#,
            "[1]",
        ] {
            assert!(decode(record(usage).as_bytes()).is_err());
        }
    }

    #[test]
    fn abi_rejects_invalid_lengths_and_can_release_empty_results() {
        let mut output = ClaudeResult::empty(IGNORED);
        // SAFETY: output is writable; the deliberately invalid null input is rejected before dereference.
        unsafe { qb_claude_decode(ptr::null(), 1, &mut output) };
        assert_eq!(output.status, INVALID_ARGUMENT);
        assert!(output.owner.is_null());
        // SAFETY: null is an explicitly supported no-op release.
        unsafe { qb_claude_free(output.owner) };
    }

    #[test]
    fn abi_layout_and_unwinding_failures_are_explicit() {
        assert_eq!(std::mem::size_of::<ClaudeResult>(), 152);
        assert_eq!(std::mem::align_of::<ClaudeResult>(), 8);
        assert_eq!(std::mem::offset_of!(ClaudeResult, counts), 8);
        assert_eq!(std::mem::offset_of!(ClaudeResult, timestamp), 48);
        assert_eq!(std::mem::offset_of!(ClaudeResult, owner), 144);
        let result = contain_failure(|| panic!("synthetic ABI failure"));
        assert_eq!(result.status, INTERNAL_ERROR);
        assert!(result.owner.is_null());
    }
}
