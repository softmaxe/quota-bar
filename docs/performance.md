# Performance validation

## Scope

The November 2026 optimization removes redundant report reads and display publications,
and accelerates the JSON classifier's traversal of long strings. It preserves the scanner's
streaming interface, prefix filtering, escape handling, file transactions, and recording rules.
Plain strings use bounded libc searches. A string with a backslash before its first candidate
quote falls back to scalar traversal from that backslash. Searching separately for every escaped
quote was rejected after a dense-escape workload exposed a regression.
The report observes `finishedLocalScans`, including failures that may follow partially successful
source scans, rather than inferring a completion from the other providers' current states.

## Repeatable classifier workload

Build the base and candidate release `QuotaBarProbe` products and keep each executable beside
its SwiftPM resource bundle. A renamed baseline executable can share the candidate's bundle
when the bundled pricing resources have not changed. Run:

```sh
uv run --no-project Scripts/benchmark_classifier.py \
  --before .build/release/QuotaBarProbeBaseline \
  --after .build/release/QuotaBarProbe --iterations 7
```

The script creates and removes isolated source directories. It generates 16 transcripts with
128 lines each (134,638,656 bytes total). Each line has a 64 KiB string before its type, and
alternates assistant usage with irrelevant user messages. Source paths are pinned to the fixture,
so the probe reads no personal logs. It alternates binary order and uses a fresh process and
temporary database for every run, with fixed offline prices. Each process checks that its cold
and unchanged incremental snapshots agree. This check is not a cross-binary equivalence proof;
recording correctness is covered by the regression suite.

Seven-run medians on the development Mac compared baseline `f023e90` with these performance
changes before integration with subsequent `main` updates:

| Workload | Before | After | Interpretation |
| --- | ---: | ---: | --- |
| Plain 64 KiB padding | 155.2 ms | 79.0 ms | 49.1% less elapsed time |
| Dense escapes, 64 KiB padding before encoding | 438.0 ms | 347.5 ms | 20.7% less elapsed time |
| No padding | 19.2 ms | 19.5 ms | Overlapping run ranges; no improvement claimed |

These are warm filesystem-cache measurements, not cold-disk startup measurements.
This workload deliberately exercises long strings and is not representative of every transcript.
The benchmark prints all runs, so future comparisons can examine noise rather than only a median.
Use `--padding-bytes 0` for short records and `--dense-escapes` for densely escaped 64 KiB
strings. The latter expands on JSON encoding and is larger than the default fixture.
Live Claude measurements varied substantially under system load and do not support a stable
real-world speedup percentage. No such percentage or memory reduction is claimed.

## Regression coverage

Run `make test`. After integration with `main`, the 1176 checks include escaped classifier keys and values, decoy markers,
long preceding values, even and odd backslash runs, unterminated strings, resuming scans,
rewrite detection, replay deduplication, source failure, pricing changes, and WAL-visible reports.
The report-update regression holds one provider's scan open while another has completed, checks
that starting a scan does not reread history, and verifies that completion publishes its cost and
status together. It uses identical completion timestamps to ensure event detection does not
rely on timestamps changing.
It explicitly awaits application of pending reads, including coalesced follow-ups, without
sleep-based synchronization. Restoring the former status observer makes the test fail on a
redundant read; restoring the former two display writes makes it fail on an intermediate display.

## Remaining candidates

Claude decoding still accounts for substantial initial-import work. Replacing Foundation's
JSON decoder or batching file transactions would require evidence and additional failure-boundary
validation. Pi and OpenCode reread snapshots when their file stamps change; caching individual
Pi files would require preserving fork deduplication, account eligibility, deletion, and failed-read
recovery. These remain candidates for representative active-session benchmarks, not proven
improvements. Absolute optimality cannot be established by these measurements.
