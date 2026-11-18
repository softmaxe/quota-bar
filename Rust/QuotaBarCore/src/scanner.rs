//! Bounded JSONL streaming. Swift owns scan plans, transactions and callback lifetimes.
use crate::find_byte;
use std::ffi::{CStr, c_char, c_int, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};

const CHUNK_SIZE: usize = 1 << 20;
const LONG_LINE_PREFIX: usize = 64 * 1024;
const EIO: i32 = 5;
const EINVAL: i32 = 22;
const EINTR: i32 = 4;
// QuotaBar targets macOS; this is Darwin's O_CLOEXEC (O_RDONLY is zero).
const O_CLOEXEC: i32 = 0x0100_0000;

unsafe extern "C" {
    fn open(path: *const c_char, flags: c_int, ...) -> c_int;
    fn read(fd: c_int, buffer: *mut c_void, count: usize) -> isize;
    fn close(fd: c_int) -> c_int;
    fn lseek(fd: c_int, offset: i64, whence: c_int) -> i64;
}

struct Descriptor(c_int);
impl Drop for Descriptor {
    fn drop(&mut self) {
        // SAFETY: this descriptor is owned and closed exactly once.
        unsafe { close(self.0) };
    }
}

fn errno() -> i32 {
    std::io::Error::last_os_error()
        .raw_os_error()
        .unwrap_or(EIO)
}

fn read_lines(
    path: &CStr,
    offset: i64,
    limit: Option<i64>,
    mut wanted: impl FnMut(&[u8]) -> bool,
    mut handle: impl FnMut(&[u8]),
) -> Result<i64, i32> {
    // SAFETY: path is terminated and borrowed for this call.
    let descriptor = unsafe { open(path.as_ptr(), O_CLOEXEC) };
    if descriptor < 0 {
        return Err(errno());
    }
    let descriptor = Descriptor(descriptor);
    let mut position = offset.max(0);
    // SAFETY: descriptor is open; SEEK_SET is zero on Darwin.
    if unsafe { lseek(descriptor.0, position, 0) } < 0 {
        return Err(errno());
    }
    let mut consumed = position;
    let mut buffer = vec![0_u8; CHUNK_SIZE];
    let mut carry = Vec::new();
    let mut skipping = false;

    while limit.is_none_or(|limit| position < limit) {
        let requested = limit.map_or(CHUNK_SIZE, |limit| {
            CHUNK_SIZE.min((limit - position) as usize)
        });
        let count = loop {
            // SAFETY: requested never exceeds the writable buffer length.
            let count = unsafe { read(descriptor.0, buffer.as_mut_ptr().cast(), requested) };
            if count >= 0 {
                break count as usize;
            }
            let error = errno();
            if error != EINTR {
                return Err(error);
            }
        };
        if count == 0 {
            break;
        }

        let mut start = 0;
        while start < count {
            let Some(distance) = find_byte(&buffer[start..count], b'\n') else {
                break;
            };
            let newline = start + distance;
            if skipping {
                skipping = false;
            } else if carry.is_empty() {
                let line = &buffer[start..newline];
                if !line.is_empty() && wanted(line) {
                    handle(line);
                }
            } else {
                carry.extend_from_slice(&buffer[start..newline]);
                if wanted(&carry) {
                    handle(&carry);
                }
                carry.clear();
            }
            consumed = position + newline as i64 + 1;
            start = newline + 1;
        }
        if start < count && !skipping {
            let was_short = carry.len() < LONG_LINE_PREFIX;
            carry.extend_from_slice(&buffer[start..count]);
            if was_short && carry.len() >= LONG_LINE_PREFIX && !wanted(&carry) {
                skipping = true;
                carry.clear();
            }
        }
        position += count as i64;
    }
    Ok(consumed)
}

type Wanted = extern "C" fn(*const u8, usize, *mut c_void) -> u8;
type Handle = extern "C" fn(*const u8, usize, *mut c_void);

/// Returns zero or a POSIX errno. Callback buffers are borrowed only during each callback.
/// The context is opaque, and every callback runs synchronously on the calling thread.
///
/// # Safety
/// `path` must point to a terminated C string, `consumed` must be writable, and callbacks must
/// accept borrowed buffers and the supplied context without unwinding or retaining pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn qb_read_lines(
    path: *const c_char,
    offset: i64,
    has_limit: u8,
    limit: i64,
    wanted: Option<Wanted>,
    handle: Option<Handle>,
    context: *mut c_void,
    consumed: *mut i64,
) -> i32 {
    if path.is_null() || consumed.is_null() {
        return EINVAL;
    }
    let (Some(wanted), Some(handle)) = (wanted, handle) else {
        return EINVAL;
    };
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the ABI caller supplies a valid terminated path.
        let path = unsafe { CStr::from_ptr(path) };
        read_lines(
            path,
            offset,
            (has_limit != 0).then_some(limit),
            |line| wanted(line.as_ptr(), line.len(), context) != 0,
            |line| handle(line.as_ptr(), line.len(), context),
        )
    }));
    match result {
        Ok(Ok(offset)) => {
            // SAFETY: the ABI caller supplies a writable output pointer.
            unsafe { *consumed = offset };
            0
        }
        Ok(Err(error)) => error,
        Err(_) => EIO,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Fixture(std::path::PathBuf, CString);
    impl Fixture {
        fn new(bytes: &[u8]) -> Self {
            let path = std::env::temp_dir().join(format!(
                "quotabar-rust-scanner-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::write(&path, bytes).unwrap();
            let c_path = CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
            Self(path, c_path)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    #[test]
    fn respects_offsets_limits_and_partial_lines() {
        let fixture = Fixture::new(b"\nfirst\nsecond\ntail");
        for (offset, limit, expected_offset, expected) in [
            (0, None, 14, vec![b"first".to_vec(), b"second".to_vec()]),
            (0, Some(4), 1, vec![]),
            (7, Some(13), 7, vec![]),
            (7, Some(14), 14, vec![b"second".to_vec()]),
            (-1, Some(7), 7, vec![b"first".to_vec()]),
            (7, Some(1), 7, vec![]),
        ] {
            let mut lines = Vec::new();
            let consumed = read_lines(
                &fixture.1,
                offset,
                limit,
                |_| true,
                |line| lines.push(line.to_vec()),
            )
            .unwrap();
            assert_eq!((consumed, lines), (expected_offset, expected));
        }
    }

    #[test]
    fn skips_rejected_multichunk_lines_and_resumes() {
        let mut bytes = vec![b'!'; CHUNK_SIZE * 3 + 37];
        bytes.extend_from_slice(b"\naccepted\npartial");
        let fixture = Fixture::new(&bytes);
        let mut lengths = Vec::new();
        let mut lines = Vec::new();
        let consumed = read_lines(
            &fixture.1,
            0,
            None,
            |line| {
                lengths.push(line.len());
                line.first() != Some(&b'!')
            },
            |line| lines.push(line.to_vec()),
        )
        .unwrap();
        assert_eq!(consumed as usize, bytes.len() - 7);
        assert_eq!(lines, vec![b"accepted".to_vec()]);
        assert_eq!(lengths, vec![CHUNK_SIZE, 8]);
    }

    #[test]
    fn accepts_multichunk_lines_without_truncation() {
        let mut bytes = vec![b'a'; CHUNK_SIZE * 2 + 73];
        bytes.push(b'\n');
        let fixture = Fixture::new(&bytes);
        let mut lines = Vec::new();
        assert_eq!(
            read_lines(
                &fixture.1,
                0,
                None,
                |_| true,
                |line| lines.push(line.to_vec())
            )
            .unwrap(),
            bytes.len() as i64
        );
        assert_eq!(lines, vec![bytes[..bytes.len() - 1].to_vec()]);
    }

    #[test]
    fn reports_open_errors_without_callbacks() {
        let fixture = Fixture::new(b"unused");
        std::fs::remove_file(&fixture.0).unwrap();
        assert_eq!(
            read_lines(&fixture.1, 0, None, |_| panic!(), |_| panic!()),
            Err(2)
        );
    }
}
