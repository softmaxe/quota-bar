//! Synchronous parsing, pricing and streaming kernels behind QuotaBar's C ABI.
//! Swift retains application state, file transactions, dates and system integration.
#![deny(unsafe_op_in_unsafe_fn)]

mod aggregation;
mod classifier;
mod claude;
mod pricing;
mod scanner;

use std::ffi::{c_int, c_void};

unsafe extern "C" {
    fn memchr(bytes: *const c_void, value: c_int, length: usize) -> *const c_void;
}

/// Bounded libc search shared by the JSON classifier and line reader.
fn find_byte(bytes: &[u8], byte: u8) -> Option<usize> {
    // SAFETY: memchr reads at most this slice's length and returns null or a pointer into it.
    unsafe {
        let found = memchr(bytes.as_ptr().cast(), byte.into(), bytes.len());
        (!found.is_null()).then(|| found.cast::<u8>().offset_from(bytes.as_ptr()) as usize)
    }
}
