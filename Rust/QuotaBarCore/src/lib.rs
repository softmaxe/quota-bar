//! Synchronous parsing, pricing and streaming kernels behind QuotaBar's C ABI.
//! Swift retains application state, file transactions, dates and system integration.
#![deny(unsafe_op_in_unsafe_fn)]

mod aggregation;
mod classifier;
mod claude;
mod pricing;
mod scanner;
