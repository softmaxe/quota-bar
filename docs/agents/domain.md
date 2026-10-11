# Domain docs

This repository uses a single-context layout:

- `GLOSSARY.md` at the repository root contains domain terms and concepts.
- `docs/adr/` contains architecture decision records.

## Before exploring the codebase

Read `GLOSSARY.md` and the ADRs relevant to the area being explored.

If these files do not exist, proceed silently. Do not propose creating
them solely because they are missing. The `domain-modeling` skill creates
them when domain terms or decisions are resolved.

## Vocabulary

Use the terms defined in `GLOSSARY.md` when naming domain concepts in
issues, proposals, hypotheses, and tests.

If a needed concept is missing, check whether an existing term covers it.
Record real vocabulary gaps for `domain-modeling`.

## Decision conflicts

If a proposal contradicts an existing ADR, identify that ADR and explain
why the decision should be reconsidered.
