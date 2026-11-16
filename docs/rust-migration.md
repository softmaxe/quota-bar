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
| Claude record decoding | `ClaudeCodeAdapter.swift:54` calls `Rust/QuotaBarCore/src/claude.rs` through a fixed C result | Rust decodes ordinary records. Foundation still handles dates, Unicode trimming/lowercasing and ID-less canonical hashing. Unsupported or ambiguous encodings fall back to the original parser before recording. |
| JSON prefix classification | `JSONLogClassifier.swift:4`, `Rust/QuotaBarCore/src/classifier.rs` | Preserve the loose classifier contract, including truncated prefixes. Bounded libc searches retain the existing long-string optimization; a pure scalar Rust version was rejected experimentally. |
| Numeric model pricing | `CostPricing.swift:93`, `Rust/QuotaBarCore/src/pricing.rs` | One call validates and prices a complete token bucket, preserving operation order, optional-rate fallback, long-context pricing and checked overflow. RateCard model lookup, aliases, dated price books, unknown-price policy and public validation diagnostics remain Swift. |
| Bounded line streaming | `LogFileScanner.swift:89`, `Rust/QuotaBarCore/src/scanner.rs` | The synchronous reader owns a descriptor and byte buffers. File discovery, stat/digest resume planning, parser state, cursor commits and transactions remain Swift. See the separate validation report for the callback cost and final acceptance evidence. |
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
| `RateCard` / `PriceBook` / `PricedUsage` | `RateCard.swift:38,72,120` and `PricedUsage.swift:34`: dated aliases, context thresholds, Fast availability, unknown prices and Pi logged-cost fallback | Numeric pricing is extracted. Cache repeated resolved lookups within a pinned refresh before adding strings and price-book ownership to FFI. |
| Codex adapter | `CodexAdapter.swift:86,162`: running totals, replay suppression and persisted parser state | Current full-chain Codex comparison exercises migrated shared kernels. A separate decoder port must compare saved state after every record, not just final totals. |
| Pi / OpenCode adapters | `PiAgentAdapter.swift:102`, `OpenCodeAdapter.swift:44`: fork identity, logged costs and coherent SQLite snapshots | Profile changed-file rescans; Swift per-file caching may eliminate more work than replacing parsing. No Rust decoder performance claim is made. |
| `UsageRecorder`, `CostCache`, backups | `UsageRecorder.swift:482`, `CostCache.swift:85,615,623`: one writer, WAL/FULL durability, per-file row/cursor/state/manifest commits and history-preserving merges | SQLite remains the same native engine. Do not split transaction ownership merely to move wrappers. Existing backup, rollback, rewrite and deduplication tests remain mandatory. |
| `CostService`, `UsageStore`, report updates | `CostService.swift:65,75,94`; `UsageStore.swift:227,257`: remote-host lease across suspension, synchronous record/read, atomic cost/status publication then completion event | Preserve actors and MainActor ownership. Existing concurrent refresh/report tests verify event ordering and coalescing. |
| HTTP, credentials, Keychain, PTY, remote sync | `ClaudeCredentials.swift:5`, `ClaudePTYRunner.swift:213`, `CodexCredentialCache.swift:42`, `RemoteLogMirror.swift:197`: Apple-signed requester identity, process cancellation, refresh generations and rsync-in-place guards | Keep platform adapters. Moving these without changing platform calls has no demonstrated CPU benefit and increases cancellation/authorization risk. Tests use fake transports and processes; real credentials were not exercised. |
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

The link-cache behavior was also tested in a minimal isolated package using byte-for-byte
copies of the actual wrappers: changing only a Rust function from returning `1` to `2`
changed both archive/executable hashes and the program's output, without cleaning or
changing Swift/C sources. Raw evidence is in `build/rust-validation/relink-test.md`.

The local release app was assembled with `make app`; its existing ad-hoc signature
passes `codesign --verify --deep --strict`. The executable is arm64, reports minimum
macOS 14.0, and has no Rust dylib dependency. Its size is 7,551,312 bytes; the complete
app is approximately 8.5 MiB and the local ZIP approximately 3.1 MiB. The local bundle
retains version `0.0.34` from the repository's release tag; this is an uncommitted
development build, not a newly published release. No installed app was replaced or
launched against personal data. The ZIP is `build/QuotaBar-rust-local-arm64.zip`, with
a matching SHA-256 file. Hosted CI and release publication have not been run.
With the identical validation hook, the original and final release probes are
2,774,256 and 3,297,824 bytes respectively (+523,568 bytes). That is a like-for-like
probe binary comparison, not a measured app-bundle size delta. The delivery manifest
binds the packaged executable and ZIP to the 186 source-input hashes used for the
final benchmark; none of the UI or resource source files changed.

Use the wrapper or Make targets. Bare `swift build`, opening the package directly in
Xcode, or consuming `QuotaBarCore` as an external Swift package does not automatically
build/link Rust. A future distributed SDK should package an XCFramework or supply a
separately validated build integration. The CI workflows now install the pinned toolchain
before their existing test/package steps; the older SDK runner and hosted release workflow
still require execution on GitHub before claiming those environments passed.

Rust adds a pinned compiler and dependency graph, native boundary debugging, archive
cache invalidation and a second set of tests. An early pricing diagnostic placed the
Swift oracle outside the Core module and did not enable whole-module optimization.
Its apparent 79.363/0.109 ms result is therefore withdrawn as comparative performance
evidence. The implementation removes per-bucket dictionary construction/sorting, which
Swift could also optimize, but only the final production-chain measurements support the
performance conclusion. No general Rust-versus-Swift language speed ratio is claimed.

The line reader was accepted only after an ablation held the other Rust kernels fixed.
With Rust versus Swift streaming, five-run initial-scan medians were 15.308/15.733 ms
(short), 43.179/42.941 ms (plain long strings), 275.545/275.911 ms (dense escapes), and
22.851/23.061 ms (Codex). Appended scans were likewise close. This supports parity in
the exercised product chain, not a streaming speedup. A minimal million-short-line
counter still regresses from 18.37 to 33.72 ms because of the two Swift callbacks;
that limitation is retained in the report rather than hidden behind other improvements.

Aggregation is also a preference-based tradeoff at small row counts. The final isolated
same-Core/WMO benchmark (including input/output conversion) improves 120/840/4,800-row
folds from 0.175/1.293/7.269 ms to 0.087/0.598/3.398 ms. However, an independent
short-record full-chain confirmation with only aggregation switched measures
16.256 ms with Swift versus 16.647 ms with Rust (+0.391 ms, +2.4%), and appended
scans 2.186 versus 2.284 ms (+0.098 ms, +4.5%). Initial-scan ranges overlap.
This small overhead is accepted under the user's near-parity preference; the module
is not claimed to accelerate every refresh. The first five-run ablation and the
targeted seven-run confirmation are both retained, rather than selecting only the
faster-looking trial. Details are in `build/rust-validation/aggregation-experiment.md`
and the validation report.

For the complete final migration against the original Swift revision, seven-run
initial-scan medians are 21.861/15.353 ms (short Claude), 83.578/44.452 ms (plain
long Claude), 401.844/277.387 ms (dense-escape Claude) and 23.317/23.089 ms (Codex).
Unchanged refreshes remain approximately equal. These include actual file scanning,
SQLite recording, pricing and snapshot construction through `CostService`, with
cross-language costs included. They do not measure network refreshes or imply an
equivalent percentage improvement in the whole application.

## Validation and rollback

The final integrated `make test` run passed 1,861 Swift harness assertions and 20
Rust unit tests, plus `cargo fmt --check` and Clippy with warnings denied. The Swift
harness includes grouped differential corpora rather than counting every generated
input as a separate assertion: over 20,000 classifier cases, more than 2,000 parser
mutations/boundaries, 6,454 pricing cases, 230 aggregation cases and the scanner
boundary suite. The existing backup, authentication mocks, remote synchronization,
report publication and UI policy checks also ran. Execution used a sandbox denying
real provider credentials/data and network access; compilation ran outside that
sandbox because SwiftPM uses its own manifest sandbox. The pre-existing Swift 6-mode
warning in `AppCheck.swift` remains; the package's Swift 5 language mode is unchanged.

See [validation methods and results](rust-validation.md) for the final repeated workload
measurements, differential database checks and UI snapshot comparison. Synthetic inputs
are intentional: the evaluation does not read personal logs, databases or credentials.
The unchanged UI source and fixture snapshots support interface compatibility, while
the complete test suite covers behavior. They cannot prove every possible real-world
log, OS release, Keychain prompt, live network race or assistive-technology interaction.

All 32 paired offscreen PNGs (26 cards and six interaction states) are byte-identical.
The original earlier baseline is retained: 27 of its images already matched, while
five reset-clock views displayed the naturally different current minute. Rerendering
the unchanged baseline binary and final debug binary in the same minute produced the
32 identical pairs without editing any pixels or production code. No UI animation
logic changed, so no new motion implementation or animation recording is claimed.

Seven fresh-process debug menu-construction measurements are 20.067 ms before and
19.975 ms after. Whole-process wall time, including the sandbox launcher, is
87.769/88.038 ms. All runs reported `menu_created=no`. These isolated startup checks
are effectively equal; they do not measure a cold disk, real account/network startup,
or the release app's complete interactive launch.

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
