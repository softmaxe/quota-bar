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
