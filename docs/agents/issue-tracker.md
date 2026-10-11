# Issue tracker: GitHub

Issues and specs live in GitHub Issues for `softmaxe/quota-bar`.
Use the `gh` CLI from this repository, which resolves the repository
from its Git remote.

## Operations

- Create: `gh issue create --title "..." --body-file <path>`
- Read: `gh issue view <number> --comments`
- Inspect labels: `gh issue view <number> --json labels`
- List: `gh issue list --state open --json number,title,body,labels,comments`
- Comment: `gh issue comment <number> --body-file <path>`
- Add a label: `gh issue edit <number> --add-label "<label>"`
- Remove a label: `gh issue edit <number> --remove-label "<label>"`
- Close: `gh issue close <number>`

Use explicit `--repo softmaxe/quota-bar` when running outside this clone.
For multiline issue bodies and comments, write the exact text to a
temporary file, pass it with `--body-file`, and delete it afterward.

When a skill says "publish to the issue tracker", create a GitHub issue.
When a skill says "fetch the relevant ticket", read the issue and its
comments.

GitHub issues and pull requests share a number space. If a reference is
ambiguous, resolve its type before choosing issue or PR commands.

## Pull requests as a triage surface

PRs as a request surface: no.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues
as tickets.

- **Map**: one issue labelled `wayfinder:map`, holding the Notes /
  Decisions-so-far / Fog body. Create it with
  `gh issue create --label wayfinder:map`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue
  (`gh api` on the sub-issues endpoint). Where sub-issues aren't enabled,
  add the child to a task list in the map body and put `Part of #<map>` at
  the top of the child body. Label it `wayfinder:<type>` (`research`,
  `prototype`, `grilling`, or `task`). Once claimed, the ticket is
  assigned to the driving dev.
- **Blocking**: use GitHub's native issue dependencies. Add an edge with
  `gh api --method POST repos/softmaxe/quota-bar/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`,
  where `<blocker-db-id>` is the blocker's numeric database id
  (`gh api repos/softmaxe/quota-bar/issues/<n> --jq .id`), not its
  `#number` or `node_id`. `issue_dependencies_summary.blocked_by` counts
  open blockers only. Where dependencies aren't available, fall back to a
  `Blocked by: #<n>, #<n>` line at the top of the child body. A ticket is
  unblocked when every blocker is closed.
- **Frontier query**: list the map's open children, scoped to its
  sub-issues or task list. Drop any with an open blocker or an assignee;
  the first remaining in map order wins.
- **Claim**: `gh issue edit <n> --add-assignee @me`, the session's first
  write.
- **Resolve**: `gh issue comment <n> --body-file <path>`, then
  `gh issue close <n>`, then append a context pointer (gist + link) to the
  map's Decisions-so-far.
