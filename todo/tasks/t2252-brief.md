<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2252: Preserve session + terminal titles across auto-compaction

## Session origin

Interactive session (maintainer-directed). User reported that after auto-compaction, the OpenCode session title, the terminal title, and the Tabby tab title all get renamed to `main`, clobbering the meaningful title set at session start.

## What

Make session + terminal titles survive the full lifecycle of an interactive OpenCode session in the canonical repo (which stays on `main` per t1990). Never write a default-branch name (`main` / `master` / `HEAD`) as any kind of session-scoped title via any aidevops code path.

## Why

`t2039` (PR #18525) added guards to `session-rename-helper.sh sync-branch` to stop THAT code path from clobbering titles with `main`. But three other aidevops code paths bypassed the helper entirely and remained unguarded:

1. **PRIMARY — reproduced live during this investigation:** `.opencode/tool/session-rename.ts`'s `sync_branch` export writes directly to the OpenCode SQLite DB via Bun's binding with zero guards. When the agent follows AGENTS.md guidance ("call `session-rename_sync_branch` after creating a branch") while the canonical repo is on `main`, it writes `main` straight into `session.title`. Reproduced live on `ses_25cef6878ffe6zGUc5Yq6ErEsS` during this session.

2. `.agents/scripts/terminal-title-helper.sh cmd_sync` (called by `pre-edit-check.sh`) emits OSC title `aidevops/main` when invoked in the canonical repo on main — with `TERMINAL_TITLE_FORMAT=branch` it emits the bare `main`.

3. The `_aidevops_terminal_title` precmd / `PROMPT_COMMAND` hook installed in `~/.zshrc` / `~/.bashrc` / fish config by `terminal-title-setup.sh` does the same unguarded OSC emit on every prompt.

OpenCode's TUI derives its terminal title from the SQLite `session.title` field, so fixing (1) cascades to terminal + Tabby titles via the TUI — (2) and (3) are independent parallel paths that must also be guarded.

User-observed evidence in `~/.local/share/opencode/opencode.db`: sessions `ses_25d5e9ce4ffe5JOcWIj8qrMDU2` and `ses_25d3a85ddffeMTaR9elkU4hNeN` were titled `main` despite t2039. Logs confirm both sessions went through `agent=compaction` + `session.compacted` publish events before the regression. Root cause: AGENTS.md guidance triggered `session-rename_sync_branch` which hit path (1) unguarded.

## How

Three defensive layers aligned with the three actual code paths:

1. **REFACTOR + EDIT** `.opencode/tool/session-rename.ts`:
   - **NEW** `.opencode/tool/session-rename-guards.ts` — pure guard module exporting `isDefaultBranchTitle(branch)` and `isTitleOverwritable(db, sessionID)` with no runtime-injected deps, so it is directly unit-testable under `bun`.
   - `session-rename.ts` imports and re-exports the guards, and replaces the body of the `sync_branch` tool with a `syncSessionWithBranch()` helper that applies both guards before writing. The default-exported `rename` tool stays unguarded (manual override, matches `session-rename-helper.sh` Test 8 semantics).
   - Guard semantics mirror `session-rename-helper.sh` verbatim so the two paths cannot drift.

2. **EDIT** `.agents/scripts/terminal-title-helper.sh`:
   - Add a `_is_default_branch` helper and call it from `cmd_sync` before generating a title. Skip OSC emit silently (`return 0`) on `main` / `master` / `HEAD` / detached HEAD.
   - `cmd_rename <explicit>` stays unguarded (manual user override).

3. **EDIT** `.agents/scripts/terminal-title-setup.sh` — update all four integration generators (`generate_zsh_omz_integration`, `generate_zsh_plain_integration`, `generate_bash_integration`, `generate_fish_integration`) so the injected `_aidevops_terminal_title` function carries the same case-statement guard with a t2252 comment for provenance.

4. **NEW** `.agents/scripts/tests/test-terminal-title-helper.sh` — shell test suite modelled on `test-session-rename-helper.sh`. 8 cases: sync skips on main/master/HEAD, sync emits on feature branches, format=branch on main still skips (guard fires before format), explicit rename is unguarded, detached HEAD skips.

5. **NEW** `.agents/scripts/tests/test-session-rename-ts.mjs` — bun-based test for the extracted TS guards. 19 cases: `isDefaultBranchTitle` on known + edge inputs (`mainline`, leading-whitespace variants), `isTitleOverwritable` on empty / default / stuck-default / meaningful titles + missing rows.

Deferred to follow-up (not blocking for this fix): a plugin-level `session.updated` event handler that would also catch OpenCode's own title-regeneration writes via the built-in `agent=title` path (outside aidevops' direct control). The three fixes above close every aidevops-owned write path; the plugin handler is belt-and-braces defense against OpenCode itself reverting our title, which has not yet been reproduced. Revisit if we observe a regression where no aidevops code path wrote `main` but the title still regressed.

## Acceptance criteria

- [ ] `.opencode/tool/session-rename.ts` `sync_branch` skips writes when branch is `main` / `master` / `HEAD` / empty.
- [ ] `.opencode/tool/session-rename.ts` `sync_branch` preserves meaningful existing titles (feature branches, LLM summaries).
- [ ] The default `rename` tool still accepts explicit titles including `main` (manual override).
- [ ] `terminal-title-helper.sh sync` never emits OSC on default branches.
- [ ] `terminal-title-helper.sh rename <explicit>` still works (manual override).
- [ ] Shell integration from `terminal-title-setup.sh install` contains the guard in all four generators (zsh-omz, zsh-plain, bash, fish).
- [ ] `test-terminal-title-helper.sh` passes all 16 assertions.
- [ ] `test-session-rename-ts.mjs` passes all 19 assertions (covers `isDefaultBranchTitle` on exact + edge inputs such as `mainline` or leading-whitespace variants).
- [ ] `test-session-rename-helper.sh` still passes (no regression).
- [ ] `shellcheck` clean on modified scripts.
- [ ] `markdownlint-cli2` clean on the brief.
- [ ] `session-rename.ts` bundles cleanly with the opencode plugin runtime.

## Verification

```bash
# In the worktree:
shellcheck .agents/scripts/terminal-title-helper.sh \
           .agents/scripts/terminal-title-setup.sh \
           .agents/scripts/tests/test-terminal-title-helper.sh
bash .agents/scripts/tests/test-terminal-title-helper.sh
bash .agents/scripts/tests/test-session-rename-helper.sh
bun  .agents/scripts/tests/test-session-rename-ts.mjs
bun build --target=bun --outfile=/dev/null .opencode/tool/session-rename-guards.ts
npx --yes markdownlint-cli2 todo/tasks/t2252-brief.md
```

## Context

- Related fix: `t2039` (PR #18525) — guarded `session-rename-helper.sh sync-branch` only; did not cover the TS tool or terminal paths.
- Rule: `t1990` — canonical repo stays on `main` always for interactive sessions.
- Architecture: OpenCode `agent=title` auto-title + `agent=compaction` summarize events are visible in `~/.local/share/opencode/log/*.log`. TUI reads session title from SQLite and propagates to OSC terminal title, which Tabby honours as the tab title.

## Tier checklist

- Files touched: 5 (2 NEW + 3 EDIT in source, 2 NEW tests, 1 EDIT brief). Cross-package: no.
- Target files >500 lines: `terminal-title-setup.sh` is 551; edits are localised to four generator functions.
- Skeleton / design decisions: the primary fix site was discovered mid-implementation (not in original brief); guards mirror existing t2039 shell helper semantics verbatim. Minimal original design.
- Estimate: ~2h end-to-end including investigation + tests.
- Acceptance criteria: 12.
- Judgment keywords: none after scope narrowed.

→ **tier:standard** (Sonnet). Not haiku-eligible (multi-file, cross-language), not opus-required (pattern well-established via t2039).

## PR Conventions

Leaf (non-parent) issue — use `Resolves #<issue>` in the PR body.
