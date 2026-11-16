//! Numeric billing for one resolved model and token bucket. Catalog and dated-rate resolution
//! stay with the caller; all arithmetic deliberately retains Swift's original operation order.

#[repr(C)]
pub struct QBModelPricing {
    pub input: f64,
    pub output: f64,
    pub cache_write: f64,
    pub cache_write_1h: f64,
    pub cache_read: f64,
    pub input_above: f64,
    pub output_above: f64,
    pub cache_write_above: f64,
    pub cache_write_1h_above: f64,
    pub cache_read_above: f64,
    pub threshold_tokens: i64,
    /// Bits 0..7 mark optional rates in field order; bit 8 marks the threshold.
    pub present: u32,
}

#[repr(C)]
pub struct QBPricingTokens {
    pub input: i64,
    pub output: i64,
    pub cache_write: i64,
    pub cache_write_1h: i64,
    pub cache_read: i64,
}

impl QBModelPricing {
    fn optional(&self, bit: u32, value: f64) -> Option<f64> {
        (self.present & (1 << bit) != 0).then_some(value)
    }

    fn input_rate(&self, long_context: bool) -> f64 {
        if long_context {
            self.optional(3, self.input_above).unwrap_or(self.input)
        } else {
            self.input
        }
    }

    fn cache_write_1h_rate(&self, long_context: bool) -> f64 {
        let above = if long_context {
            self.optional(6, self.cache_write_1h_above)
        } else {
            None
        };
        above
            .or(self.optional(1, self.cache_write_1h))
            .unwrap_or_else(|| self.input_rate(long_context) * 2.0)
    }

    /// Boolean counterpart of RateRules' diagnostics for the fixed public ModelPricing fields.
    /// Validate every stated rate, even when this bucket does not use that rate.
    fn valid(&self) -> bool {
        let nonnegative = |rate: f64| rate.is_finite() && rate >= 0.0;
        if !nonnegative(self.input) || !nonnegative(self.output) {
            return false;
        }
        let optional = [
            self.cache_write,
            self.cache_write_1h,
            self.cache_read,
            self.input_above,
            self.output_above,
            self.cache_write_above,
            self.cache_write_1h_above,
            self.cache_read_above,
        ];
        for (bit, rate) in optional.into_iter().enumerate() {
            if self.present & (1 << bit) != 0 && !nonnegative(rate) {
                return false;
            }
        }
        if self.present & (1 << 8) != 0 {
            if self.threshold_tokens <= 0 || self.threshold_tokens >= 1_000_000_000_000 {
                return false;
            }
        } else if self.present & 0b1111_1000 != 0 {
            return false;
        }
        // Both implicit one-hour rates are validated, regardless of the selected context tier.
        self.cache_write_1h_rate(false).is_finite() && self.cache_write_1h_rate(true).is_finite()
    }

    fn cost(&self, tokens: &QBPricingTokens, long_context: bool) -> Option<f64> {
        if !self.valid()
            || [
                tokens.input,
                tokens.output,
                tokens.cache_write,
                tokens.cache_write_1h,
                tokens.cache_read,
            ]
            .into_iter()
            .any(|count| count < 0)
        {
            return None;
        }
        let input = self.input_rate(long_context);
        let above = |bit, value| {
            if long_context {
                self.optional(bit, value)
            } else {
                None
            }
        };
        let output = above(4, self.output_above).unwrap_or(self.output);
        let write = above(5, self.cache_write_above)
            .or(self.optional(0, self.cache_write))
            .unwrap_or(input);
        let read = above(7, self.cache_read_above)
            .or(self.optional(2, self.cache_read))
            .unwrap_or(input);
        let write_1h_rate = self.cache_write_1h_rate(long_context);
        let write_1h = tokens.cache_write_1h.min(tokens.cache_write) as f64;
        // Subtract after integer-to-double conversion, matching the original rounding at 2^53.
        let write_5m = tokens.cache_write as f64 - write_1h;
        let millionths = tokens.input as f64 * input
            + tokens.output as f64 * output
            + write_5m * write
            + write_1h * write_1h_rate
            + tokens.cache_read as f64 * read;
        if millionths.is_finite() {
            return Some(millionths / 1_000_000.0);
        }
        let cost = tokens.input as f64 * (input / 1_000_000.0)
            + tokens.output as f64 * (output / 1_000_000.0)
            + write_5m * (write / 1_000_000.0)
            + write_1h * (write_1h_rate / 1_000_000.0)
            + tokens.cache_read as f64 * (read / 1_000_000.0);
        (cost.is_finite() && cost >= 0.0).then_some(cost)
    }
}

/// Returns 1 and writes the cost when valid; returns 0 without writing otherwise.
///
/// # Safety
/// Non-null pointers must point to aligned, initialized ABI structs or writable output storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qb_pricing_cost(
    pricing: *const QBModelPricing,
    tokens: *const QBPricingTokens,
    long_context: u8,
    out_cost: *mut f64,
) -> u8 {
    if pricing.is_null() || tokens.is_null() || out_cost.is_null() {
        return 0;
    }
    // SAFETY: The caller provides valid storage according to the C ABI contract above.
    match unsafe { (&*pricing).cost(&*tokens, long_context != 0) } {
        Some(cost) => {
            unsafe { *out_cost = cost };
            1
        }
        None => 0,
    }
}

/// Resolves the one-hour rate without validation, matching the public Swift accessor.
///
/// # Safety
/// A non-null pointer must point to an aligned, initialized ABI struct.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qb_pricing_cache_write_1h_rate(
    pricing: *const QBModelPricing,
    long_context: u8,
) -> f64 {
    if pricing.is_null() {
        return f64::NAN;
    }
    // SAFETY: The caller provides valid storage according to the C ABI contract above.
    unsafe { (&*pricing).cache_write_1h_rate(long_context != 0) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ptr;

    fn pricing() -> QBModelPricing {
        QBModelPricing {
            input: 3.0,
            output: 15.0,
            cache_write: 0.0,
            cache_write_1h: 0.0,
            cache_read: 0.0,
            input_above: 0.0,
            output_above: 0.0,
            cache_write_above: 0.0,
            cache_write_1h_above: 0.0,
            cache_read_above: 0.0,
            threshold_tokens: 0,
            present: 0,
        }
    }

    fn tokens() -> QBPricingTokens {
        QBPricingTokens {
            input: 1_000_000,
            output: 0,
            cache_write: 0,
            cache_write_1h: 0,
            cache_read: 0,
        }
    }

    #[test]
    fn abi_layout_is_fixed_width() {
        assert_eq!(std::mem::size_of::<QBModelPricing>(), 96);
        assert_eq!(std::mem::offset_of!(QBModelPricing, threshold_tokens), 80);
        assert_eq!(std::mem::offset_of!(QBModelPricing, present), 88);
        assert_eq!(std::mem::size_of::<QBPricingTokens>(), 40);
    }

    #[test]
    fn invalid_calls_preserve_output_storage() {
        let mut pricing = pricing();
        let tokens = tokens();
        let mut output = 42.0;
        // SAFETY: All non-null pointers refer to live aligned values for each call.
        unsafe {
            assert_eq!(qb_pricing_cost(ptr::null(), &tokens, 0, &mut output), 0);
            assert_eq!(qb_pricing_cost(&pricing, ptr::null(), 0, &mut output), 0);
            assert_eq!(qb_pricing_cost(&pricing, &tokens, 0, ptr::null_mut()), 0);
            pricing.output = f64::NAN;
            assert_eq!(qb_pricing_cost(&pricing, &tokens, 0, &mut output), 0);
            assert!(qb_pricing_cache_write_1h_rate(ptr::null(), 0).is_nan());
        }
        assert_eq!(output, 42.0);
    }

    #[test]
    fn valid_call_writes_cost_and_keeps_inputs() {
        let pricing = pricing();
        let tokens = tokens();
        let mut output = 0.0;
        // SAFETY: Inputs and output are initialized local ABI values.
        unsafe {
            assert_eq!(qb_pricing_cost(&pricing, &tokens, 0, &mut output), 1);
            assert_eq!(qb_pricing_cache_write_1h_rate(&pricing, 0), 6.0);
        }
        assert_eq!(output, 3.0);
        assert_eq!(tokens.input, 1_000_000);
        assert_eq!(pricing.input, 3.0);
    }
}
