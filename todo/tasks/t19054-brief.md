# t19054: fix(plugin): let repo-rooted sessions run bounded operations in registered-repo worktrees

## Origin

- **Created:** 2026-11-16
- **Session:** OpenCode interactive productivity mission
- **Created by:** marcusquinn (interactive)

## What

`aidevops_bounded_operation` (and the GPT image tool, which shares the resolver) rejects a session-owned linked worktree of a repo registered in `repos.json` when the OpenCode session started inside a *different* Git repository. A session rooted in the framework repo that full-loops a PR in another registered repo gets:

```json
{"schema":"aidevops.interactive-operation/v1","error":"Operation workdir belongs to an unrelated Git repository."}
```

## Why

Interactive sessions routinely start in the framework repo and orchestrate work in other registered repos. The rejection forces long-running work (required-check waits, full-loop merges with canonical sync, test suites) back onto foreground Bash with hard timeouts. Observed 2026-11-16: `full-loop-helper.sh merge` for a registered-repo PR was rejected by the bounded tool and had to run as blocking Bash. Earlier in the same mission a registered-repo check wait was rejected the same way.

GH#33228 / PR #33325 already accepts registered repos when the session root is a non-Git parent directory (`registeredCanonicalRoot`). A repo-rooted session takes the earlier `startupIdentity.commonDir !== requestedIdentity.commonDir` branch and throws before the registry is consulted.

## How

- `.agents/plugins/opencode-aidevops/gpt-image-worktree.mjs` — `verifyRepositoryRelation()`: accept the same repo (unchanged); for a non-repo parent keep `pathIsWithin(startupRoot, canonicalRoot)`; for both cases fall back to `registeredCanonicalRoot(canonicalRoot)` before throwing. Keep the existing error text so current assertions match.
- All other safety properties stay: absolute path, no symlink, linked worktree (not canonical), and `verifyRegisteredOwnership` (worktree registry owner = current session) still runs after the relation check.
- `.agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs` — add a repo-rooted case next to "non-Git parent accepts owned child worktree…": unregistered other repo rejects; registered other repo resolves.

## Acceptance

- A session rooted in repo A can start a bounded operation in a session-owned linked worktree of registered repo B.
- Unregistered repo B, canonical checkouts and symlinks are still rejected; ownership verification still runs.
- `node --test .agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs .agents/plugins/opencode-aidevops/tests/test-gpt-image-tool.mjs` passes.

## Files Scope

- `.agents/plugins/opencode-aidevops/gpt-image-worktree.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs`
