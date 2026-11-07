# Merging and releasing

## Merge a pull request

The `main` ruleset allows squash merges only and requires `Check (macos-15)`
and `Check (xcode-27)` to pass on a branch that is up to date with `main`.
The PR title becomes the squash commit title on `main` and the PR body its
message, so the title must be a Conventional Commit.

1. If the branch is behind `main`, run `gh pr update-branch <n>`; this
   re-runs CI.
2. Run `gh pr merge <n> --squash --auto`. Auto-merge lands the PR once the
   required checks pass and does not update a branch that falls behind in the
   meantime; repeat step 1 if it stalls.

For check status, use `gh pr checks <n> --required`. CodeQL runs in the
background and is not a merge gate; its completion is independent of this
procedure. If a required check is pending, use the host's PR watch mechanism
and resume when it reports a change.

Documentation-only PRs complete the same required checks on Linux without
compiling. Other changes retain both macOS checks and release packaging.

Done when `gh pr view <n> --json state --jq .state` prints `MERGED`.
When a PR introduces the custom CodeQL workflow, also complete the one-time
[CodeQL activation](../ci.md#activate-the-codeql-workflow) after merging.

## Publish a release

A pushed `vMAJOR.MINOR.PATCH` tag runs **Build and Release**, which packages,
publishes the GitHub Release, and bumps `softmaxe/homebrew-tap`. Regression
tests run before merge in PR CI.

1. Run `git fetch origin --tags` and list the unreleased commits with
   `git log --oneline "$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' origin/main)"..origin/main`.
   If there are none, there is nothing to release; report that and stop.
2. Increment the PATCH of that tag by one, whatever the commit types
   (`v0.0.1` → `v0.0.2`, `v0.0.9` → `v0.0.10`).
3. Tag `main` and push the tag:
   `git tag -a vX.Y.Z -m "QuotaBar X.Y.Z" origin/main`, then
   `git push origin vX.Y.Z`.
4. Find the run with
   `gh run list --workflow release.yml --branch vX.Y.Z --limit 1`, then
   `gh run watch <id> --exit-status`.

Done when **Preflight**, **Build arm64**, **Release**, and
**Update Homebrew tap** all succeed.

Tags and releases are permanent: rulesets forbid deleting or moving `v*`
tags, and published releases are immutable. **Preflight** rejects a tag
whose commit is not on `main`. When a run fails, re-run it with
`gh run rerun <id> --failed` if the cause was transient; otherwise fix it on
`main` and release the next patch version.
