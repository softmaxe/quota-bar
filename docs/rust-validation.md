# Rust migration validation

## Scope and baseline

The measurements were taken during the migration included in `96fc2af`, using Swift
commit `f8df98b129c9138ccb9e6290d6c801e805fed1be` as the reference. The candidate
contained Rust kernels for Claude decoding, structural JSON classification, bounded
JSONL streaming, token-rate arithmetic and usage aggregation. See
[Migration boundaries](rust-migration.md) for their architecture. The migration keeps
Swift's file planning, inode/size checks, CryptoKit prefix digests and memoization,
SQLite transactions, scan cursors, recording rules, dates, authentication and UI.
Within the filesystem layer, only `LogFileScanner.readLines` moves its
read/line-walking loop to Rust. The Rust
function calls Swift's filter and handler synchronously with borrowed byte views;
Swift still drains each accepted record's autorelease pool.

The implementation preserves the 1 MiB read buffer, strict absolute scan limit,
complete-line offset, incomplete trailing line, Darwin `O_CLOEXEC`, interrupted-read
retry, and 64 KiB threshold for early rejection of irrelevant long lines. An
accepted long line can still grow the carry buffer, as it did before. Rejected
lines are skipped without retaining the remainder. No file data is memory mapped.
`qb_read_lines` returns POSIX errno on failure and catches Rust panics as `EIO`.

## Focused differential checks

`RustLogFileScannerTests` compares the actual Swift-to-Rust boundary with the frozen
Swift implementation in `SwiftLogLineScanner.swift`. It checks all inspected
prefixes, accepted bytes, callback order, consumed offsets and errors, rather than
only counting lines. Cases include empty records, CRLF, incomplete tails, negative
and beyond-end offsets, limits inside records, boundaries at 1 MiB, multi-chunk
accepted/rejected records, arbitrary non-UTF-8 bytes and a Unicode filename.
Separate checks cover missing files, reading a directory and recursively scanning
from a callback. The production Swift wrapper and Rust static library passed all
82 focused assertions in an isolated optimized build; all four Rust scanner unit
tests and `cargo clippy --all-targets -- -D warnings` also passed. The existing recorder/scanner suite retains append, rewrite,
partial-line, persisted resume-state, deduplication and transaction coverage.

Run these with the full suite:

```sh
make test
```

The Rust unit tests independently cover offset/limit behavior, multi-chunk
acceptance/rejection and file-open errors:

```sh
make rust-check
```

## Streaming measurement

The final isolated comparison compiles the production Swift wrapper and Rust
reader beside the frozen Swift loop in the same optimized executable. Both the
filter and accepted-line handler cross FFI in the Rust case, including Swift's
per-record autorelease pool. Seven alternating rounds use three scans per
invocation and warm filesystem caches. The run had an exclusive timing window.
Every invocation returned identical consumed offsets, accepted counts and bytes.

| Synthetic input | Bytes | Swift | Rust with both Swift callbacks |
| --- | ---: | ---: | ---: |
| 1,000,000 short lines | 16,000,000 | 18.37 ms | 33.72 ms |
| 2,048 lines with 64 KiB payloads | 134,219,776 | 11.92 ms | 11.84 ms |
| 16 rejected 8 MB lines | 128,000,032 | 11.16 ms | 11.14 ms |

The minimal short-line workload exposes a regression of about 15 ns per line;
these callbacks only inspect a byte and count records. The long-line and rejected
large-line cases are effectively equal. No scanner speedup is claimed. The full
pipeline comparison includes the actual classifier, decoding, recording and
pricing work and determines the practical effect; a loop-only measurement cannot
substitute for it. This is also not a cold-disk or live-history measurement.

An earlier exploratory version kept the first-byte rejection predicate in Rust
and crossed FFI only for the handler. It measured 18.45/10.06 ms on short lines,
but omitted the final filter boundary and therefore does not describe production
performance. The final table above supersedes those timings.

The standalone scanner microbenchmark was a local experiment. The repository preserves
its correctness corpus in `RustLogFileScannerTests` and the Rust scanner unit tests.

## Scanner ablation in the complete pipeline

A separate five-round alternating comparison restored only the original Swift
`LogFileScanner.swift` in a temporary copy of the four-kernel candidate. It kept
the Rust Claude parser, classifier and pricing implementation identical. Both
binaries used the same fixture hook, offline prices and database path isolation.
The seven lifecycle phases and every benchmark's snapshots, schema, rows and
cursor contents matched.

| Workload | Initial scan, Rust / Swift scanner | Append 64 records, Rust / Swift scanner |
| --- | ---: | ---: |
| Short Claude | 15.308 / 15.733 ms | 2.085 / 2.084 ms |
| Plain 64 KiB Claude | 43.179 / 42.941 ms | 2.108 / 2.059 ms |
| Dense escapes Claude | 275.545 / 275.911 ms | 2.134 / 2.109 ms |
| Codex | 22.851 / 23.061 ms | 1.996 / 2.042 ms |

The complete-pipeline scanner comparison is effectively equal. It supports
retaining the Rust reader under the chosen preference for migration at comparable
performance, while preserving the short-line microbenchmark caveat above. It
does not attribute the other kernels' gains to the scanner.

## Final complete-pipeline results

The final candidate includes the Unicode spelling preservation fix in aggregation.
All seven lifecycle checkpoints and all 28 alternating benchmark pairs matched
snapshots, schema, persisted rows and cursor contents. The full regression suite
passed 1,861 Swift assertions and 20 Rust tests.

| Synthetic workload | Initial scan, Swift / final | Append 64 records, Swift / final | Unchanged scan, Swift / final |
| --- | ---: | ---: | ---: |
| Short Claude | 21.861 / 15.353 ms | 2.446 / 2.175 ms | 1.531 / 1.555 ms |
| Plain 64 KiB Claude | 83.578 / 44.452 ms | 2.404 / 2.080 ms | 1.638 / 1.662 ms |
| Dense escapes Claude | 401.844 / 277.387 ms | 2.563 / 2.143 ms | 1.745 / 1.713 ms |
| Codex | 23.317 / 23.089 ms | 2.016 / 1.981 ms | 0.904 / 0.906 ms |

These are seven-run medians of the actual `CostService` pipeline, including file
planning, filtering, decoding, recording, SQLite and pricing. The first scan uses
a new database; unchanged scans and append scans reuse that process's service.
Codex and unchanged scans are effectively equal. The three Claude fixtures show
lower initial-import elapsed time, but are synthetic workloads rather than a
claim about every history or the app's startup time.

The equally instrumented release probes were 2,774,256 bytes before and
3,297,824 bytes after, an increase of 523,568 bytes (about 0.50 MiB).

## Aggregation ablation and its tradeoff

In the isolated same-module, whole-module-optimized benchmark, the original Swift
aggregator folded 120, 840 and 4,800 rows in 0.175, 1.293 and 7.269 ms respectively.
The Rust aggregator took 0.087, 0.598 and 3.398 ms including input/output conversion.

The corrected final candidate was compared with a temporary copy restoring only
`CostAggregator.swift` from the original revision. Every other Rust kernel stayed
the same. Five alternating rounds passed the same lifecycle and per-run database
and snapshot comparisons.

| Workload | Initial scan, Rust / Swift aggregation | Append, Rust / Swift aggregation |
| --- | ---: | ---: |
| Short Claude | 17.140 / 16.270 ms | 2.333 / 2.160 ms |
| Plain 64 KiB Claude | 43.304 / 44.031 ms | 2.138 / 2.142 ms |
| Dense escapes Claude | 278.566 / 277.940 ms | 2.194 / 2.240 ms |
| Codex | 22.573 / 22.947 ms | 2.044 / 1.992 ms |

The short fixture's difference warranted one targeted seven-round confirmation.
It measured 16.647 / 16.256 ms initially, an observed 0.391 ms (2.4%) overhead;
append measured 2.284 / 2.186 ms, an observed 0.098 ms (4.5%) overhead. Initial-scan
ranges overlap (15.71–17.56 / 15.12–17.27 ms). The migration retains this kernel
under the chosen preference for comparable performance: small-group conversion
work has a modest cost even though larger isolated aggregation workloads improve.
This is not evidence that aggregation accelerates every complete scan. No further
runs were added after that confirmation.

## Reproducing full pipeline validation

```sh
uv run --no-project Scripts/validate_rust_pipeline.py \
  --revision f8df98b129c9138ccb9e6290d6c801e805fed1be \
  --output "$(mktemp -d /tmp/quota-rust-validation.XXXXXX)/run" --iterations 7
```

The output must be a new directory. The script copies only whitelisted build
sources from the baseline revision and current working tree, and injects
`Scripts/fixtures/rust_pipeline_hook.swift` into those isolated probe copies.
The product probe gets no extra command or behavior. Source hashes, executable
hashes and sizes, commands, build logs, raw stdout/stderr, SQLite databases and
per-run timing arrays are retained. Reusable probes must have matching binary
and hook manifests; `--reuse-sources` additionally checks every source hash
before reusing build output.

The hook supplies explicit synthetic source paths and fixed offline prices to
`CostService`. It never changes `HOME`. A runtime sandbox denies network access,
real provider directories, Keychains and QuotaBar's application data. No actual
provider or credential process is run. Every probe process has a new database;
its initial scan is followed by an unchanged scan, appending 64 records, and a
second unchanged scan. Wall elapsed includes the sandbox launcher and probe
serialization, so it is not application startup latency.

The seven lifecycle checkpoints cover an incomplete final line, unchanged input,
append/replay, copied-file deduplication, a rewrite retaining Claude history,
unpriced/invalid input, and source deletion retaining recorded history. Every
SQLite column and schema entry is checked. Only `file_cursor.resume_state` is
parsed as JSON when comparing: Swift's encoder can reorder dictionary keys.
No values are discarded, and unnormalized rows remain under `raw_tables`.

The development machine is an Apple M2 Pro with 32 GiB RAM, macOS 27.2.1,
Swift 6.4 and Rust 1.98. These are fresh-process, warm-filesystem synthetic
measurements, not cold-disk or personal-history measurements. Seven-run medians
should be read with their retained ranges; they do not imply a universal app
speedup or reduced memory usage.

## Visual baseline

An isolated source archive of the reference commit built the original debug app.
Only its documented offscreen commands ran:

```sh
QuotaBar --dump-card build/rust-validation/before/card
QuotaBar --dump-interaction-states build/rust-validation/before/interactions
```

This captured 26 card variants and six interaction-state images using sample data.
The output is ignored build data. Neither command reads CLI credentials, scans
personal sessions or starts the normal application integrations. The same commands
on the final candidate initially produced 27 byte-identical PNGs. The five
`*-reset-clock.png` files differed because the sample factory uses the current
minute for its absolute reset labels.

The untouched baseline binary and final binary were then rendered consecutively
within the same minute, without editing any pixels or source. All 32 resulting
PNGs are byte-identical: 26 card variants and six interaction states, including
light/dark, sign-in and refresh failure. The comparison covered static rendering.

## Menu construction and process startup

Seven alternating invocations of the original and final debug apps used the
existing isolated `--benchmark-menu-startup` flag. Every invocation reported
`menu_created=no`. Status-item construction medians were 20.067 / 19.975 ms;
external process-wall medians were 87.769 / 88.038 ms. The ranges overlap and no
startup improvement is claimed.

The flag does not start provider integrations or scan logs. Both binaries ran
with the same runtime sandbox; process-wall time includes its launcher and normal
process loading/exit. These are fresh-process, warm-filesystem observations, not
cold-disk application-launch measurements.

## Boundaries retained in Swift

The SQLite recorder already uses SQLite's C engine and reuses prepared statements.
Moving its wrapper alone would not replace the query engine; changing transaction
batching would change failure boundaries. This migration retains one writable
connection, existing schema/backup compatibility, per-file transactions, cursor
updates and recorder merge rules. No SQLite performance gain is claimed.

Network/authentication migration has no measured CPU benefit here. URLSession,
Keychain access through the Apple-signed `security` process, credential refresh
coordination and PTY cancellation remain in their existing platform layer. They
were reviewed from source, without invoking real providers or credential stores.
