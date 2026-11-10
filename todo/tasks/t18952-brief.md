## What

Add one sentence to `.agents/reference/session.md` (ask rules, ~L90–91): routine engineering choices within the session's own authority are decisions, not asks. Examples: which of its own PRs carries a change, merge or stack order, splitting or combining commits. Pick the recommended option and record the rationale in the PR body.

## Why

On 2026-11-10 an interactive session asked the maintainer whether a display-source union belonged in PR #37495 or in the stacked PR #37497, and recommended an answer. The maintainer replied "1 as recommended. you could have made that decisions, that's routine ai work." The existing rule "Decide scope/policy questions the repo already answers" did not obviously cover placement between the session's own PRs, because the repo has no explicit policy for it.

## How

1. `.agents/reference/session.md`: after "Decide scope/policy questions the repo already answers (for example the test policy) instead of asking.", add the sentence above. No other files change. `.agents/AGENTS.md` stays untouched (size ratchet).

## Acceptance

- `rg -n "which of its own PRs" .agents/reference/session.md` returns one line in the ask rules.
- Markdown lint passes for the changed file.

### Files Scope

- .agents/reference/session.md
