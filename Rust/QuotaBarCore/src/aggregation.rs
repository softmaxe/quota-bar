//! Folds already priced, SQL-reduced rows. Swift supplies its actual day traversal order and
//! retains all strings, calendar operations, output models, and top-model tie policy.

use std::{
    collections::HashMap,
    panic::{AssertUnwindSafe, catch_unwind},
    slice,
};

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct QBAggregateTokens {
    pub input: i64,
    pub output: i64,
    pub cache_write: i64,
    pub cache_write_1h: i64,
    pub cache_read: i64,
}

#[repr(C)]
pub struct QBAggregateRow {
    pub day: u64,
    pub key: u64,
    pub model: u64,
    pub tokens: QBAggregateTokens,
    pub cost: f64,
    pub unpriced: i64,
    pub priced: u8,
    pub fallback: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct QBAggregateGroup {
    pub day: u64,
    pub key: u64,
    pub tokens: QBAggregateTokens,
    pub cost: f64,
    pub priced: u8,
    pub fallback: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct QBAggregateDay {
    pub tokens: QBAggregateTokens,
    pub cost: f64,
    pub unpriced: i64,
    pub priced: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct QBAggregateModel {
    pub cost: f64,
    pub tokens: i64,
    pub priced: u8,
}

const INVALID_COUNTS: i32 = 1;
const TOKEN_OVERFLOW: i32 = 2;
const TOTAL_OVERFLOW: i32 = 3;
const WINDOW_OVERFLOW: i32 = 4;
const INVALID_COST: i32 = 5;
const INVALID_ARGUMENT: i32 = 6;
const INTERNAL_ERROR: i32 = 7;

impl QBAggregateTokens {
    fn total(self) -> Option<i64> {
        if [
            self.input,
            self.output,
            self.cache_write,
            self.cache_write_1h,
            self.cache_read,
        ]
        .into_iter()
        .any(|value| value < 0)
            || self.cache_write_1h > self.cache_write
        {
            return None;
        }
        self.input
            .checked_add(self.output)?
            .checked_add(self.cache_write)?
            .checked_add(self.cache_read)
    }

    /// The order and distinct errors match TokenTotals.adding, including its final total check.
    fn adding(self, other: Self) -> Result<Self, i32> {
        self.total().ok_or(INVALID_COUNTS)?;
        other.total().ok_or(INVALID_COUNTS)?;
        let add = |lhs: i64, rhs: i64| lhs.checked_add(rhs).ok_or(TOKEN_OVERFLOW);
        let result = Self {
            input: add(self.input, other.input)?,
            output: add(self.output, other.output)?,
            cache_write: add(self.cache_write, other.cache_write)?,
            cache_write_1h: add(self.cache_write_1h, other.cache_write_1h)?,
            cache_read: add(self.cache_read, other.cache_read)?,
        };
        result.total().ok_or(TOTAL_OVERFLOW)?;
        Ok(result)
    }
}

fn add_tokens(lhs: i64, rhs: i64) -> Result<i64, i32> {
    if lhs < 0 || rhs < 0 {
        return Err(WINDOW_OVERFLOW);
    }
    lhs.checked_add(rhs).ok_or(WINDOW_OVERFLOW)
}

fn add_cost(lhs: f64, rhs: f64) -> Result<f64, i32> {
    let result = lhs + rhs;
    if lhs >= 0.0 && rhs >= 0.0 && result.is_finite() {
        Ok(result)
    } else {
        Err(INVALID_COST)
    }
}

fn fold(
    rows: &[QBAggregateRow],
    groups: &mut [QBAggregateGroup],
    days: &mut [QBAggregateDay],
    models: &mut [QBAggregateModel],
) -> Result<u64, i32> {
    days.fill(QBAggregateDay::default());
    models.fill(QBAggregateModel::default());
    let mut indexes = HashMap::with_capacity(rows.len());
    let mut group_count = 0;
    for row in rows {
        let day = days
            .get_mut(usize::try_from(row.day).map_err(|_| INVALID_ARGUMENT)?)
            .ok_or(INVALID_ARGUMENT)?;
        let model = models
            .get_mut(usize::try_from(row.model).map_err(|_| INVALID_ARGUMENT)?)
            .ok_or(INVALID_ARGUMENT)?;
        let index = *indexes.entry((row.day, row.key)).or_insert_with(|| {
            let index = group_count;
            groups[index] = QBAggregateGroup {
                day: row.day,
                key: row.key,
                ..Default::default()
            };
            group_count += 1;
            index
        });
        let group = &mut groups[index];
        // Preserve the Swift fold's check and accumulation order exactly.
        group.tokens = group.tokens.adding(row.tokens)?;
        day.tokens = day.tokens.adding(row.tokens)?;
        model.tokens = add_tokens(model.tokens, row.tokens.total().ok_or(INVALID_COUNTS)?)?;
        if row.fallback != 0 {
            group.fallback = 1;
        }
        if row.priced != 0 {
            day.cost = add_cost(day.cost, row.cost)?;
            day.priced = 1;
            group.cost = add_cost(group.cost, row.cost)?;
            group.priced = 1;
            model.cost = add_cost(model.cost, row.cost)?;
            model.priced = 1;
        }
        if row.unpriced > 0 {
            day.unpriced = add_tokens(day.unpriced, row.unpriced)?;
        }
    }
    Ok(group_count as u64)
}

/// Folds rows synchronously into caller-owned buffers. A nonzero status invalidates all outputs.
/// Group capacity must be at least row_count. Null buffers are allowed only for zero counts.
///
/// # Safety
/// Every nonempty buffer must reference aligned, initialized storage for its count. All buffers
/// must be disjoint and remain alive for the call; group_count must be writable and non-null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qb_aggregate_usage(
    rows: *const QBAggregateRow,
    row_count: u64,
    day_count: u64,
    model_count: u64,
    groups: *mut QBAggregateGroup,
    group_count: *mut u64,
    days: *mut QBAggregateDay,
    models: *mut QBAggregateModel,
) -> i32 {
    if group_count.is_null() {
        return INVALID_ARGUMENT;
    }
    // SAFETY: The caller guarantees writable storage for group_count.
    unsafe {
        *group_count = 0;
    }
    let Ok(row_count) = usize::try_from(row_count) else {
        return INVALID_ARGUMENT;
    };
    let Ok(day_count) = usize::try_from(day_count) else {
        return INVALID_ARGUMENT;
    };
    let Ok(model_count) = usize::try_from(model_count) else {
        return INVALID_ARGUMENT;
    };
    if row_count > isize::MAX as usize / std::mem::size_of::<QBAggregateRow>()
        || row_count > isize::MAX as usize / std::mem::size_of::<QBAggregateGroup>()
        || day_count > isize::MAX as usize / std::mem::size_of::<QBAggregateDay>()
        || model_count > isize::MAX as usize / std::mem::size_of::<QBAggregateModel>()
    {
        return INVALID_ARGUMENT;
    }
    if (row_count > 0 && (rows.is_null() || groups.is_null()))
        || (day_count > 0 && days.is_null())
        || (model_count > 0 && models.is_null())
    {
        return INVALID_ARGUMENT;
    }
    // SAFETY: Counts and pointers satisfy the caller's contract. Empty slices do not dereference
    // nullable zero-length buffers. Rust borrows all storage only for this synchronous call.
    let result = catch_unwind(AssertUnwindSafe(|| unsafe {
        let rows = if row_count == 0 {
            &[]
        } else {
            slice::from_raw_parts(rows, row_count)
        };
        let groups = if row_count == 0 {
            &mut []
        } else {
            slice::from_raw_parts_mut(groups, row_count)
        };
        let days = if day_count == 0 {
            &mut []
        } else {
            slice::from_raw_parts_mut(days, day_count)
        };
        let models = if model_count == 0 {
            &mut []
        } else {
            slice::from_raw_parts_mut(models, model_count)
        };
        fold(rows, groups, days, models)
    }));
    match result {
        Ok(Ok(count)) => {
            // SAFETY: The caller guarantees writable storage for group_count.
            unsafe {
                *group_count = count;
            }
            0
        }
        Ok(Err(status)) => status,
        Err(_) => INTERNAL_ERROR,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ptr;

    fn row() -> QBAggregateRow {
        QBAggregateRow {
            day: 0,
            key: 0,
            model: 0,
            tokens: QBAggregateTokens {
                input: 1,
                ..Default::default()
            },
            cost: 1.0,
            unpriced: 0,
            priced: 1,
            fallback: 0,
        }
    }

    fn run(rows: &[QBAggregateRow]) -> Result<u64, i32> {
        fold(
            rows,
            &mut vec![QBAggregateGroup::default(); rows.len()],
            &mut [QBAggregateDay::default()],
            &mut [QBAggregateModel::default()],
        )
    }

    #[test]
    fn fixed_width_layout() {
        assert_eq!(std::mem::size_of::<QBAggregateTokens>(), 40);
        assert_eq!(std::mem::size_of::<QBAggregateRow>(), 88);
        assert_eq!(std::mem::offset_of!(QBAggregateRow, tokens), 24);
        assert_eq!(std::mem::offset_of!(QBAggregateRow, cost), 64);
        assert_eq!(std::mem::size_of::<QBAggregateGroup>(), 72);
        assert_eq!(std::mem::size_of::<QBAggregateDay>(), 64);
        assert_eq!(std::mem::size_of::<QBAggregateModel>(), 24);
    }

    #[test]
    fn token_errors_keep_their_distinct_statuses() {
        let mut invalid = row();
        invalid.tokens.input = -1;
        assert_eq!(run(&[invalid]), Err(INVALID_COUNTS));
        let mut maximum = row();
        maximum.tokens.input = i64::MAX;
        assert_eq!(run(&[maximum, row()]), Err(TOKEN_OVERFLOW));
        let mut maximum = row();
        maximum.tokens.input = i64::MAX;
        let mut output = row();
        output.tokens.input = 0;
        output.tokens.output = 1;
        assert_eq!(run(&[maximum, output]), Err(TOTAL_OVERFLOW));
        let mut maximum = row();
        maximum.unpriced = i64::MAX;
        let mut next = row();
        next.unpriced = 1;
        assert_eq!(run(&[maximum, next]), Err(WINDOW_OVERFLOW));
    }

    #[test]
    fn cost_validation_and_optional_zero() {
        for cost in [-1.0, f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let mut invalid = row();
            invalid.cost = cost;
            assert_eq!(run(&[invalid]), Err(INVALID_COST));
        }
        let mut unpriced = row();
        unpriced.priced = 0;
        unpriced.cost = f64::NAN;
        let mut zero = row();
        zero.cost = 0.0;
        for row in [unpriced, zero] {
            let priced = row.priced;
            let mut groups = [QBAggregateGroup::default()];
            let mut days = [QBAggregateDay::default()];
            let mut models = [QBAggregateModel::default()];
            assert_eq!(fold(&[row], &mut groups, &mut days, &mut models), Ok(1));
            assert_eq!((groups[0].priced, groups[0].cost), (priced, 0.0));
            assert_eq!((days[0].priced, days[0].cost), (priced, 0.0));
            assert_eq!((models[0].priced, models[0].cost), (priced, 0.0));
        }
    }

    #[test]
    fn abi_empty_and_invalid_arguments() {
        let mut count = 99;
        // SAFETY: Zero-length buffers may be null and count is live writable output storage.
        unsafe {
            assert_eq!(
                qb_aggregate_usage(
                    ptr::null(),
                    0,
                    0,
                    0,
                    ptr::null_mut(),
                    &mut count,
                    ptr::null_mut(),
                    ptr::null_mut()
                ),
                0
            );
            assert_eq!(count, 0);
            assert_eq!(
                qb_aggregate_usage(
                    ptr::null(),
                    1,
                    0,
                    0,
                    ptr::null_mut(),
                    &mut count,
                    ptr::null_mut(),
                    ptr::null_mut()
                ),
                INVALID_ARGUMENT
            );
            assert_eq!(
                qb_aggregate_usage(
                    ptr::null(),
                    0,
                    0,
                    0,
                    ptr::null_mut(),
                    ptr::null_mut(),
                    ptr::null_mut(),
                    ptr::null_mut()
                ),
                INVALID_ARGUMENT
            );
        }
        let mut invalid = row();
        invalid.day = 1;
        assert_eq!(run(&[invalid]), Err(INVALID_ARGUMENT));
    }

    #[test]
    fn abi_rejects_unrepresentable_slice_lengths_before_borrowing() {
        let input = row();
        let mut group = QBAggregateGroup::default();
        let mut day = QBAggregateDay::default();
        let mut model = QBAggregateModel::default();
        let mut count = 99;
        for (rows, days, models) in [(u64::MAX, 1, 1), (1, u64::MAX, 1), (1, 1, u64::MAX)] {
            // SAFETY: Oversized counts are rejected before any buffer is borrowed or dereferenced.
            assert_eq!(
                unsafe {
                    qb_aggregate_usage(
                        &input, rows, days, models, &mut group, &mut count, &mut day, &mut model,
                    )
                },
                INVALID_ARGUMENT
            );
            assert_eq!(count, 0);
        }
    }
}
