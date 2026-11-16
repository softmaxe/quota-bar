# Continuous integration

PRs keep the two required checks, `Check (macos-15)` and `Check (xcode-27)`.
CI compares the PR merge tree with its base commit. The documentation allowlist
in `Scripts/ci_requires_build.sh` lets both checks finish on Linux without a
macOS build. Any other path runs the existing tests and release packaging.
Classification errors fail the required checks.

CodeQL scans Swift, Rust, Python, JavaScript/TypeScript, and Actions after pushes to `main`,
weekly, and on manual dispatch. It is independent of PR merging. Review scan
failures and security alerts separately from the required PR checks.

Every Swift build job (PR checks, release packaging and CodeQL's manual Swift
build) installs the toolchain pinned in `rust-toolchain.toml` before invoking
`Scripts/swift.sh`. `make test` checks Rust formatting, unit tests and Clippy
before the Swift assertion suite. Packaging links the release static archive
and retains the existing signature and architecture checks. Rust source, Cargo
manifest/lockfile, C bridge and toolchain changes all require both macOS checks;
they are outside the documentation allowlist.

The Rust CodeQL job uses `build-mode: none` on Linux, as supported by
[CodeQL's Rust analysis](https://github.blog/changelog/2025-10-14-codeql-scanning-rust-and-c-c-without-builds-is-now-generally-available/).
It does not execute the Darwin-specific native kernels. Dependabot checks the
Cargo manifest and lockfile in `Rust/QuotaBarCore` monthly, alongside the existing
GitHub Actions updates. Compiler updates remain explicit changes to the pinned
toolchain and must pass both macOS checks.

## Activate the CodeQL workflow

This is a one-time migration from GitHub default setup. Complete it after
`.github/workflows/codeql.yml` has merged into `main`: default setup blocks
analysis uploads from custom workflows, so adding the YAML alone is not enough.

1. Confirm the workflow is present on `main`:
   `gh api 'repos/softmaxe/quota-bar/contents/.github/workflows/codeql.yml?ref=main' --jq .path`.
2. Disable default setup:
   `gh api --method PATCH repos/softmaxe/quota-bar/code-scanning/default-setup -f state=not-configured`.
3. Enable the custom workflow and dispatch its first scan:
   `gh workflow enable codeql.yml`, then
   `gh workflow run codeql.yml --ref main`.
4. Inspect the resulting run using `gh run list --workflow codeql.yml` and
   `gh run view <id>`. Migration is complete when all configured language jobs
   succeed, including analysis upload. Fix and rerun failures before considering
   the migration complete.

Keep CodeQL outside the required status checks. If migration cannot be completed,
restore default setup with
`gh api --method PATCH repos/softmaxe/quota-bar/code-scanning/default-setup -f state=configured`
until the custom workflow is fixed.
