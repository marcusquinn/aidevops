# t2181: fix detectTaskId regex for canonical worktree path shapes

ref: GH#19643
origin: interactive (opencode, maintainer session)
parent: t2177 (PR #19635, merged d5f5c8c)

## What

`detectTaskId(cwd)` in `.agents/plugins/opencode-aidevops/otel-enrichment.mjs`
extracts the aidevops task ID from the current working directory so the
`aidevops.task_id` OTEL attribute can be attached to every tool span. The
regex shipped in t2177 matches only the `<type>/<name>` worktree shape — the
default produced by plain `git worktree add feature/t1234-desc`. The
framework's own `wt` helper produces `~/Git/<repo>.<type>-<name>` (dot
separator) or `~/Git/<repo>-<type>-<name>` (dash separator), neither of
which match. Result: in the common case `aidevops.task_id=""`.

## Why

`aidevops.task_id` is the primary join key from OTEL traces back to
TODO.md entries. t2177's PR body promised that attribute as the payoff
for adding the enrichment module at all. A zero-match regex on the
dominant worktree convention guts that value.

Discovered empirically: I wrote t2177 inside
`~/Git/aidevops.feature-t2177-otel-introspect`, ran `detectTaskId` against
`process.cwd()`, got `""`. This is a self-caught regression inside the
same feature, same session.

## How

Replace both regexes in `otel-enrichment.mjs`:

- Line 126: `/\/[a-z]+[-/]t(\d+)(?:-|$|\/)/i` → `/[^a-z0-9]t(\d+)(?:[-/]|$)/i`
- Line 128: `/\/[a-z]+[-/]gh-(\d+)(?:-|$|\/)/i` → `/[^a-z0-9]gh-(\d+)(?:[-/]|$)/i`

The `[^a-z0-9]` class is any non-alphanumeric character — covers `.`
(dot), `-` (dash), `/` (slash), and any future separator convention. The
existing trailing group `(?:[-/]|$)` stays: task ID must be followed by
dash, slash, or end-of-string.

Verified in node REPL against 4 canonical shapes + 1 negative:

| Path | Expected | Got |
|------|----------|-----|
| `~/Git/aidevops.feature-t2177-otel-introspect` | `t2177` | `t2177` |
| `~/Git/aidevops-feature-t2181-desc` | `t2181` | `t2181` |
| `/repo/worktrees/feature/t100-desc` | `t100` | `t100` |
| `~/Git/x.bugfix-gh-19634-name` | `GH#19634` | `GH#19634` |
| `/home/user/patient123/stuff` | `""` | `""` |

### Files

- EDIT: `.agents/plugins/opencode-aidevops/otel-enrichment.mjs:126,128` — swap regexes; update `@example` block in JSDoc to list all three shapes.
- NEW: `.agents/plugins/opencode-aidevops/tests/test-otel-enrichment.mjs` — Node native `node:assert/strict` test; 8 assertions covering 3 worktree shapes (2 task types each), env-var precedence, false-positive negative case.

## Acceptance

1. All 8 test assertions pass under plain `node <file>`.
2. `detectTaskId("~/Git/aidevops.feature-t2177-otel-introspect")` returns `"t2177"`.
3. `detectTaskId("/home/x/patient123")` returns `""` (no false positive on the `t` in "patient").
4. JSDoc `@example` / `@returns` block updated.
5. No regression in `test-session-introspect.sh`.

## Verification

```bash
node .agents/plugins/opencode-aidevops/tests/test-otel-enrichment.mjs
.agents/scripts/tests/test-session-introspect.sh
```

## Risk

Tiny. Pure regex swap in a single function. The function is called from
`quality-hooks.mjs:handleToolBefore`, already wrapped in a try/catch at
the call site (see `enrichActiveSpan`). Worst case on regex error:
returns `""`, same as today's buggy behavior — no new failure mode.

## Why tier:simple

- One file edit with verbatim old/new strings.
- One new test file, Node native API, no scaffolding.
- Target file 154 lines, well under 500.
- Zero cross-package changes, zero credentials, zero decomposition.
- 3 disqualifier checks from task-taxonomy.md: all pass.
