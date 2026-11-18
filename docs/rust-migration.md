# Rust core migration

The migration follows an explicit product preference: Rust is acceptable at performance
parity, provided the existing macOS interface, saved history, accounting and operational
behavior remain compatible. It does not attempt to replace the application with Rust.
The reference Swift implementation is commit `f8df98b129c9138ccb9e6290d6c801e805fed1be`.

## Implemented boundaries

P1 boundaries are record decoding, classification and numeric pricing. P2 boundaries
are reduced-row aggregation and streaming: both passed differential validation, with
streaming accepted for product-chain parity under the user's language preference.

| Boundary | Implementation and code evidence | Rationale and retained ownership |
| --- | --- | --- |
| Claude record decoding | `ClaudeCodeAdapter.swift` calls `Rust/QuotaBarCore/src/claude.rs` through a fixed C result | Rust decodes ordinary records. Foundation still handles dates, Unicode trimming/lowercasing and ID-less canonical hashing. Unsupported or ambiguous encodings fall back to the original parser before recording. |
| JSON prefix classification | `JSONLogClassifier.swift`, `Rust/QuotaBarCore/src/classifier.rs` | Preserve the loose classifier contract, including truncated prefixes. Bounded libc searches retain the existing long-string optimization; a pure scalar Rust version was rejected experimentally. |
| Numeric model pricing | `CostPricing.swift`, `Rust/QuotaBarCore/src/pricing.rs` | One call validates and prices a complete token bucket, preserving operation order, optional-rate fallback, long-context pricing and checked overflow. RateCard model lookup, aliases, dated price books, unknown-price policy and public validation diagnostics remain Swift. |
| Bounded line streaming | `LogFileScanner.swift`, `Rust/QuotaBarCore/src/scanner.rs` | The synchronous reader owns a descriptor and byte buffers. File discovery, stat/digest resume planning, parser state, cursor commits and transactions remain Swift. See the separate validation report for the callback cost and final acceptance evidence. |
| Priced-row aggregation | `CostAggregator.swift`, `Rust/QuotaBarCore/src/aggregation.rs` | Rust folds already-priced rows into per-key/day/model totals. Swift supplies day/key identities and reconstructs existing presentation models; Calendar, SQL, pricing policy and top-model tie policy remain Swift. |

The C header is [QuotaBarRust.h](../Sources/CQuotaBarRust/include/QuotaBarRust.h).
Swift wrappers use pointers and lengths, fixed-width numeric fields and explicit optional
flags. There is no JSON serialization of results, Rust executor, asynchronous callback,
new database connection, schema migration, settings change or UI implementation change.

## Compatibility and FFI

Each Claude call borrows one complete JSON record, not an entire JSONL file. The returned
strings belong to one Rust allocation; Swift copies them before a deferred
`qb_claude_free`. Embedded NUL is retained through length-delimited strings. The original
Foundation decoder remains a production compatibility path for floating token spellings,
duplicate known keys, unsupported shapes, ID-less canonical hashes and decoder failures.
The differential tests compare all request fields, including identity, token buckets,
dates and Fast mode. They also exercise malformed/truncated records and arbitrary bytes.

Rust pricing validates counts and rates before arithmetic and preserves the Swift
floating-point operation sequence. Its tests compare optional results and exact `Double`
bit patterns across 6,454 cases, including all 512 optional-field masks, random finite and
non-finite values, negative counts and overflow fallback. This does not replace tests of
price-book policy: those continue to exercise the unchanged Swift layer.

Aggregation crosses once per already-priced snapshot. Swift interns day, model and
usage keys into numeric IDs and owns the input/output buffers. Rust preserves the
original group-token, day-token, model-total, day/group/model-cost and unpriced-total
check order. Swift supplies its actual day-dictionary traversal order, preserving
cross-day floating-point accumulation, then sorts the resulting days as before.
Error codes map back to the original `RecordedUsageReaderError.invalidData` messages.
Top-model selection stays Swift, including its existing unspecified winner when both
cost and token totals are exactly tied. No new alphabetical tie-break is introduced.
Both sides assert ABI layout; impossible slice lengths are rejected before borrowing.
Usage-key interning is local to each day, and model token/cost dictionaries retain their
separate first key spellings. This preserves Swift's original UTF-8 representation even
when two model or upstream strings are canonically equivalent Unicode spellings. The
additional tests compare raw UTF-8 bytes, because Swift string equality alone would
hide that difference.

Scanner callbacks run synchronously on the actor's current thread. Their byte views and
context cannot escape. The Swift wrapper keeps callback closures alive, retains the
per-record autorelease pool, and releases its context after the call. No second worker
or cancellation model is introduced. The existing scanner is synchronous too: task
cancellation does not interrupt an in-progress file read; cancellation and publication
continue at the existing Swift orchestration boundaries.

The crate uses `panic = "unwind"`. Allocation/parsing and scanner entry points contain
unwinding panics and return fallback/error status; they do not unwind through Swift.
The classifier and fixed-size arithmetic paths avoid fallible allocations and use
checked/bounded operations. Unit tests assert C/Rust layouts, and a Claude unit test
injects an unwinding panic. This is not process isolation: invalid caller pointers,
aborting panics and allocation aborts are not made recoverable by `catch_unwind`.

The choice of a small static library follows the official [Rust linkage reference](https://doc.rust-lang.org/reference/linkage.html).
Panic limitations follow [the standard library contract](https://doc.rust-lang.org/std/panic/fn.catch_unwind.html).
The deployment target uses the documented [Apple target environment variable](https://doc.rust-lang.org/rustc/platform-support/apple-darwin.html).
These references were checked during implementation. UniFFI is unnecessary for this
small internal synchronous ABI; no claim is made that it is intrinsically slower.

## Modules retained in Swift

Technical feasibility alone does not establish a compatible, useful migration. These
modules are intentionally retained; absence of a Rust port is not a claim that Rust
could never implement them.
Codex/Pi/OpenCode decoders and additional price-book transforms are P3 investigation
candidates. Database ownership, application concurrency, platform integration and UI
are excluded from this migration; they are not pending implementation work.

| Module | Evidence and reason | Future experiment or alternative |
| --- | --- | --- |
| `RateCard` / `PriceBook` / `PricedUsage` | `RateCard.swift` and `PricedUsage.swift`: dated aliases, context thresholds, Fast availability, unknown prices and Pi logged-cost fallback | Numeric pricing is extracted. Cache repeated resolved lookups within a pinned refresh before adding strings and price-book ownership to FFI. |
| Codex adapter | `CodexAdapter.swift`: running totals, replay suppression and persisted parser state | Current full-chain Codex comparison exercises migrated shared kernels. A separate decoder port must compare saved state after every record, not just final totals. |
| Pi / OpenCode adapters | `PiAgentAdapter.swift`, `OpenCodeAdapter.swift`: fork identity, logged costs and coherent SQLite snapshots | Profile changed-file rescans; Swift per-file caching may eliminate more work than replacing parsing. No Rust decoder performance claim is made. |
| `UsageRecorder`, `CostCache`, backups | `UsageRecorder.swift`, `CostCache.swift`: one writer, WAL/FULL durability, per-file row/cursor/state/manifest commits and history-preserving merges | SQLite remains the same native engine. Do not split transaction ownership merely to move wrappers. Existing backup, rollback, rewrite and deduplication tests remain mandatory. |
| `CostService`, `UsageStore`, report updates | `CostService.swift`; `UsageStore.swift`: remote-host lease across suspension, synchronous record/read, atomic cost/status publication then completion event | Preserve actors and MainActor ownership. Existing concurrent refresh/report tests verify event ordering and coalescing. |
| HTTP, credentials, Keychain, PTY, remote sync | `ClaudeCredentials.swift`, `ClaudePTYRunner.swift`, `CodexCredentialCache.swift`, `RemoteLogMirror.swift`: Apple-signed requester identity, process cancellation, refresh generations and rsync-in-place guards | Keep platform adapters. Moving these without changing platform calls has no demonstrated CPU benefit and increases cancellation/authorization risk. Tests use fake transports and processes; real credentials were not exercised. |
| SwiftUI / AppKit / WebKit / settings | `UsageStore.swift`, `SettingsStore.swift`, `UsageReportWindowController.swift` | Preserve the required product surface and platform ownership. No Rust UI rewrite is proposed. |

## Build and maintenance

Install full Xcode and rustup (for example `brew install rustup`, with its bin directory
on `PATH`). `rust-toolchain.toml` pins Rust; `Cargo.lock` pins dependencies. Normal entry
points remain:

```sh
make test
make app
Scripts/swift.sh build -c release --product QuotaBarProbe
```

`Scripts/swift.sh` runs a locked Cargo build before Swift build/run/test commands and
links the matching debug or release archive. A digest-derived Swift compiler flag makes
Rust-only changes invalidate SwiftPM's link cache. The archive is statically linked;
app users do not install Rust or receive a separate Rust dylib. Both toolchains target
macOS 14. The current package/release path is a native arm64 build. Cross-architecture
and universal builds are not implemented by this wrapper.

## Validation and rollback

Run `make test` for the current regression suite. It checks Rust formatting, unit tests
and Clippy, then runs the Swift harness against the linked archive. The harness compares
classifier, Claude parser, pricing, scanner and aggregation results with their Swift
reference implementations. It also covers recording, backup, authentication mocks,
report publication and UI policy.

The [migration validation report](rust-validation.md) records the original performance
measurements, database comparisons, startup timings and offscreen image comparisons.
It includes the command for comparing another working tree with the Swift baseline.
The migration accepted the line reader and aggregator at comparable end-to-end
performance. The short-line callback benchmark and small-row aggregation measurements
in the report qualify that result.

The migration has no data-format or settings upgrade. Rollback is a code/build rollback:
restore the affected adapters/kernels and remove Rust build integration, then rebuild the
original Swift version. Existing histories and backups do not need conversion. The
original Claude Foundation path is already retained; frozen classifier, scanner and
pricing oracles remain in tests for future differential regression. Do not switch
implementations midway through a file transaction.

Future changes must retain zero unexplained request/state/row/cursor differences; keep
full refresh and callback costs in measurements; rerun the backup, cancellation,
remote-sync and report-event suite; and follow `design-implementation.md` for affected
UI previews. A new speed claim needs representative end-to-end evidence, not only a
kernel microbenchmark.
