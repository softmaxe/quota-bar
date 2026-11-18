# Continuous integration

PRs keep the two required checks, `Check (macos-15)` and `Check (xcode-27)`.
CI compares the PR merge tree with its base commit. The documentation allowlist
in `Scripts/ci_requires_build.sh` lets both checks finish on Linux without a
macOS build. Any other path runs the existing tests and release packaging.
Classification errors fail the required checks.

The `macos-15` check also renders the offline usage report with synthetic data
and runs the browser assertions against the runner's Chrome installation. The
report tools use the Node version in `.node-version` and the pnpm lockfile.

CodeQL scans Swift, Rust, Python, JavaScript/TypeScript, and Actions after pushes to `main`,
weekly, and on manual dispatch. It is independent of PR merging. Review scan
failures and security alerts separately from the required PR checks.

Swift analysis traces a manual build on `macos-15` with Xcode 16.4. GitHub
supports Swift build tracing through Xcode 26. The macOS 27 SDK branches are
compiled by the required `xcode-27` PR check and the release build.
See [GitHub's Swift tracing support](https://github.blog/changelog/2026-10-19-codeql-changes-for-macos-27-xcode-27-and-swift-6-4/).

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
Cargo dependencies, report tooling dependencies, and GitHub Actions monthly.
Rust compiler updates are explicit changes to the pinned toolchain and must
pass both macOS checks.

The repository uses the custom CodeQL workflow with GitHub default setup
disabled. Inspect individual language jobs with `gh run list --workflow codeql.yml`
and `gh run view <id>`.
