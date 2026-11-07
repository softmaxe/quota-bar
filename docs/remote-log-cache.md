# Remote log cache

Remote session logs are a temporary input to Recorded usage. The SQLite database
stores the usage and the state required to continue reading a session; the mirror
stores the original JSONL, which can also contain prompts and tool output.

## Cleanup invariants

- Never delete anything on the SSH host or in this Mac's CLI session directories.
- Only evict a local mirrored file after its complete contents have been recorded.
  A successful transfer alone does not establish this.
- Keep recent files available for active sessions and incremental transfers.
- Preserve usage, file identity, scan position, parser state, and host association
  when evicting a mirror. Eviction must not change recorded totals.
- Persist the recovery evidence before removing the original bytes. A failed
  deletion may waste space, but must not lose usage or prevent a retry.
- Revalidate an evicted file against the remote source on each sync. An eviction
  is evidence about one file version, never a permanent exclusion of its path.
- If an evicted session grows, verify the previously consumed contents before
  resuming its saved parser. Do not replay old records into existing aggregates.
- Preserve the downloaded file and recorded history when old contents have been
  rewritten or truncated. An uncertain recovery is not a cleanup candidate.
- A failed scan, incomplete trailing line, cancellation, or unavailable validation
  must not produce a new deletion authorization.
- Serialize transfer, recording, and cleanup for a host. Background scans must
  not consume an in-progress transfer.

## Storage and network tradeoffs

The retention window is 24 hours from observing a recorded file version. Existing
installations certify fully consumed, unchanged logs without replaying their
messages, then start that window. A partial trailing line can become eligible once
completed; malformed JSON keeps the file ineligible. Duplicate session copies,
paths that cannot be safely expressed as literal sync rules, and cursors without
the required parser state remain cached.

Validation uses `sha256sum` or `shasum -a 256` through a POSIX shell on the remote
host, in batches of up to 32 files per SSH request. If these tools are unavailable,
sync falls back to downloading rather than trusting an unverified eviction.

Eviction reduces steady local storage. If an evicted session changes, its complete
file may need to be downloaded again before the new portion can be recorded.
Keeping recent files avoids this cost for active sessions. Unchanged evicted files
need validation rather than another transfer of their conversation contents.

Content validation requires reading the old file on the remote host. This uses
remote disk and CPU even when no session contents cross the network. Validation
failures must remain visible or fall back conservatively; they must never be
interpreted as proof that a remote file is unchanged.

The Usage database size excludes cached remote JSONL. Removing cached JSONL does
not remove the usage already saved in SQLite. Backups must preserve the recorded
history; exclusion eligibility must always be tied to the current database's
recording evidence.

The host row labels its contribution as `unique` and its remaining local log size
as `cached`. Historical records remain visible when no cached files remain.
Importing a backup invalidates local eviction proofs and marks remote cursors for
copy recovery; downloaded files must be certified again before another eviction.

## Regression checks

Use synthetic sessions, temporary databases, and a fake command runner for
transfer failures. Check unchanged syncs, restart after eviction, resumed sessions,
shared session identities, partial lines, rewritten historical bytes, failed
recording, and cancellation. Assert both the recorded totals and whether the
original local file is retained. Run `make test` for core and app regressions.
